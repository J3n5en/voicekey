package j3.voicekey

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.concurrent.thread
import org.json.JSONException
import org.json.JSONObject

/** 发布仓库，和 app/src-tauri/tauri.conf.json 里 updater endpoints 的仓库保持一致；fork 的人改这一处 */
private const val REPO = "J3n5en/voicekey"
private const val MANIFEST_URL = "https://github.com/$REPO/releases/latest/download/android.json"
private const val CHECK_INTERVAL_MS = 12 * 60 * 60 * 1000L

/** 应用内更新：拉 android.json → 下载 APK 并校验 sha256 → 交给系统 PackageInstaller（系统会弹确认框，不做静默安装） */
object Updater {
    sealed interface State {
        data object Idle : State
        data object Checking : State
        data object Latest : State
        data class Available(val m: Manifest) : State
        data class Downloading(val progress: Float) : State
        data object Installing : State
        data class Error(val msg: String) : State
    }

    data class Manifest(val versionCode: Long, val versionName: String, val url: String, val sha256: String, val size: Long)

    var state by mutableStateOf<State>(State.Idle)
        private set

    /** 系统安装确认页的 Intent，应用在后台时拉不起来，回到前台再补拉 */
    var confirm: Intent? = null
        internal set

    /** MainActivity 是否在前台，决定 InstallReceiver 能否直接拉起确认页 */
    @Volatile
    internal var foreground = false

    private var confirmLaunched = false

    fun currentVersion(ctx: Context): Pair<Long, String> {
        val info = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
        val code = if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else @Suppress("DEPRECATION") info.versionCode.toLong()
        return code to (info.versionName ?: "")
    }

    /** 手动检查失败会报错；自动检查（打开应用时，12 小时一次）失败静默并保持原状态 */
    fun check(ctx: Context, manual: Boolean) {
        when (state) {
            State.Checking, is State.Downloading, State.Installing -> return
            else -> {}
        }
        val now = System.currentTimeMillis()
        if (!manual) {
            if (now - App.prefs.updateCheckedAt < CHECK_INTERVAL_MS) return
            App.prefs.updateCheckedAt = now
        }
        val prev = state
        val cur = currentVersion(ctx).first
        state = State.Checking
        thread(name = "vk-update-check") {
            val r = runCatching { fetchManifest() }
            state = r.fold(
                { m -> if (m.versionCode > cur) State.Available(m) else State.Latest },
                { if (manual) State.Error(it.message ?: it.toString()) else prev },
            )
        }
    }

    private fun fetchManifest(): Manifest {
        val c = URL(MANIFEST_URL).openConnection() as HttpURLConnection
        c.connectTimeout = 15_000
        c.readTimeout = 30_000
        try {
            if (c.responseCode != 200) error("检查更新失败 HTTP ${c.responseCode}")
            val text = c.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
            val m = try {
                val o = JSONObject(text)
                Manifest(o.getLong("versionCode"), o.getString("versionName"), o.getString("url"), o.getString("sha256"), o.getLong("size"))
            } catch (e: JSONException) {
                error("更新清单格式错误")
            }
            if (!m.url.startsWith("https://") || m.size <= 0 || !SHA256_HEX.matches(m.sha256)) error("更新清单格式错误")
            return m
        } finally {
            c.disconnect()
        }
    }

    /** 只在 Available 状态执行；没授权安装未知应用就跳授权页，用户回来后再点一次 */
    fun install(ctx: Context) {
        val m = (state as? State.Available)?.m ?: return
        if (!ctx.packageManager.canRequestPackageInstalls()) {
            ctx.startActivity(Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${ctx.packageName}")))
            return
        }
        state = State.Downloading(0f)
        val app = ctx.applicationContext
        thread(name = "vk-update-install") {
            val part = File(app.cacheDir, "update.apk.part")
            var session: PackageInstaller.Session? = null
            try {
                download(m, part)
                val installer = app.packageManager.packageInstaller
                val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
                    setAppPackageName(app.packageName)
                    setSize(m.size)
                }
                session = installer.openSession(installer.createSession(params))
                part.inputStream().use { input ->
                    session.openWrite("base.apk", 0, m.size).use { out ->
                        input.copyTo(out)
                        session.fsync(out)
                    }
                }
                // 系统要往回调 intent 里填 extras，必须 MUTABLE；intent 是显式指向 InstallReceiver 的
                val flags = PendingIntent.FLAG_UPDATE_CURRENT or if (Build.VERSION.SDK_INT >= 31) PendingIntent.FLAG_MUTABLE else 0
                val cb = PendingIntent.getBroadcast(app, 0, Intent(app, InstallReceiver::class.java), flags)
                // 先置 Installing 再 commit，免得回调比这行先到、又被它覆盖
                state = State.Installing
                session.commit(cb.intentSender)
            } catch (e: Throwable) {
                runCatching { session?.abandon() }
                state = State.Error(e.message ?: e.toString())
            } finally {
                part.delete()
                runCatching { session?.close() }
            }
        }
    }

    private fun download(m: Manifest, part: File) {
        val c = URL(m.url).openConnection() as HttpURLConnection
        c.connectTimeout = 15_000
        c.readTimeout = 30_000
        try {
            if (c.responseCode != 200) error("下载失败 HTTP ${c.responseCode}")
            val md = MessageDigest.getInstance("SHA-256")
            var n = 0L
            var last = 0L
            c.inputStream.use { input ->
                part.outputStream().use { out ->
                    val buf = ByteArray(1 shl 16)
                    while (true) {
                        val k = input.read(buf)
                        if (k < 0) break
                        out.write(buf, 0, k)
                        md.update(buf, 0, k)
                        n += k
                        val now = SystemClock.elapsedRealtime()
                        if (now - last > 200) {
                            last = now
                            state = State.Downloading((n.toFloat() / m.size).coerceIn(0f, 1f))
                        }
                    }
                }
            }
            if (n != m.size || md.digest().joinToString("") { "%02x".format(it) } != m.sha256.lowercase()) {
                part.delete()
                error("安装包校验失败（大小/sha256 不符）")
            }
        } finally {
            c.disconnect()
        }
    }

    /** 「继续安装」按钮：重新拉起系统确认页 */
    fun showConfirm(ctx: Context) = launchConfirm(ctx)

    /** 回到前台时补拉一次因后台启动限制没弹出的确认页；已经弹过的不重复拉 */
    fun resumeConfirm(ctx: Context) {
        if (state == State.Installing && !confirmLaunched) launchConfirm(ctx)
    }

    internal fun launchConfirm(ctx: Context) {
        val i = confirm ?: return
        confirmLaunched = true
        runCatching { ctx.startActivity(i) }.onFailure { state = State.Error("无法打开安装确认：${it.message ?: it}") }
    }

    internal fun onInstallStatus(ctx: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        when (status) {
            PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                val i = if (Build.VERSION.SDK_INT >= 33) {
                    intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                } else {
                    @Suppress("DEPRECATION") intent.getParcelableExtra(Intent.EXTRA_INTENT)
                }
                if (i == null) {
                    state = State.Error("安装失败：系统没有给出确认页")
                    return
                }
                confirm = i.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                confirmLaunched = false
                // 应用在后台时系统会拦下，留给 resumeConfirm 与「继续安装」按钮
                if (foreground) launchConfirm(ctx)
            }
            PackageInstaller.STATUS_SUCCESS -> {
                confirm = null
                state = State.Idle
            }
            else -> {
                confirm = null
                val msg = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
                val head = if (status == PackageInstaller.STATUS_FAILURE_ABORTED) "已取消安装" else "安装失败"
                state = State.Error("$head（status=$status）：$msg")
            }
        }
    }

    private val SHA256_HEX = Regex("[0-9a-fA-F]{64}")
}

/** PackageInstaller 的提交结果回调，在 AndroidManifest 里登记（exported=false） */
class InstallReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) = Updater.onInstallStatus(context, intent)
}
