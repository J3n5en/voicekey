package j3.voicekey

import android.os.SystemClock
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import kotlin.concurrent.thread

/** 微信离线：从微信输入法 CDN 下载官方语音包，校验后由 Rust 解包 */
object WtOffline {
    var progress by mutableStateOf<Float?>(null)
        private set
    var error by mutableStateOf<String?>(null)
        private set
    var ready by mutableStateOf(Native.wtofflineReady())
        private set

    fun download() {
        if (ready || progress != null) return
        progress = 0f
        error = null
        thread(name = "vk-wtoffline") {
            val r = runCatching { install() }
            progress = null
            ready = Native.wtofflineReady()
            r.onFailure { error = it.message ?: it.toString() }
        }
    }

    private fun install() {
        val (url, size, md5) = Native.wtofflineInfo().split("\n")
        val part = File(App.app.filesDir, "wtoffline.part")
        val c = URL(url).openConnection() as HttpURLConnection
        c.connectTimeout = 15_000
        c.readTimeout = 30_000
        if (c.responseCode != 200) error("下载失败 HTTP ${c.responseCode}")
        val md = MessageDigest.getInstance("MD5")
        val total = size.toLong()
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
                        progress = n.toFloat() / total * 0.97f
                    }
                }
            }
        }
        if (md.digest().joinToString("") { "%02x".format(it) } != md5) {
            part.delete()
            error("语音包校验失败")
        }
        progress = 0.98f
        val err = Native.wtofflineUnpack(part.path)
        part.delete()
        if (err != null) error(err)
    }
}
