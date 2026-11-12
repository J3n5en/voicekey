package j3.voicekey

import android.annotation.SuppressLint
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.webkit.CookieManager
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebStorage
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

/** 用系统 WebView 打开官方登录页，登录 Cookie 联网校验通过后写入 accounts.json */
class LoginActivity : ComponentActivity() {
    private val main = Handler(Looper.getMainLooper())
    private var id = ""
    private var page = ""
    private var domain = ""
    private var titleText = "登录"
    private var pageUrl: String? = null
    private var armed = false
    private var done = false
    private var fresh = true
    private var checking = false
    private var lastPicked = ""
    private var triedAt = 0L
    private var saveWarned = false
    private var web: WebView? = null
    private var loadProgress by mutableIntStateOf(0)
    private var status by mutableStateOf<String?>(null)

    private val poll = object : Runnable {
        override fun run() {
            if (done) return
            consider()
            if (!done) main.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // 被系统回收后重建（如切去短信 App 取验证码）不清 Cookie，保留登录进度
        fresh = savedInstanceState == null
        id = intent.getStringExtra(EXTRA_ID).orEmpty()
        page = Native.loginPage(id)
        domain = Native.loginDomain(id)
        titleText = Channel.of(id)?.title ?: "登录"
        if (page.isEmpty() || domain.isEmpty()) {
            Toast.makeText(this, "无法打开登录页", Toast.LENGTH_SHORT).show()
            finish()
            return
        }
        enableEdgeToEdge()
        setContent { MaterialTheme { Surface(Modifier.fillMaxSize()) { LoginScreen() } } }
    }

    override fun onDestroy() {
        done = true
        main.removeCallbacks(poll)
        super.onDestroy()
    }

    @Composable
    private fun LoginScreen() {
        val shown = loadProgress
        Column(Modifier.fillMaxSize().systemBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Column(Modifier.weight(1f).padding(start = 8.dp)) {
                    Text(titleText, style = MaterialTheme.typography.titleMedium)
                    Text(status ?: "在页面中完成登录，成功后自动返回", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                TextButton({
                    done = true
                    main.removeCallbacks(poll)
                    finish()
                }) { Text("取消") }
            }
            if (shown in 1..99) LinearProgressIndicator({ shown / 100f }, Modifier.fillMaxWidth())
            AndroidView(
                factory = { createWeb().also { web = it; start(it) } },
                modifier = Modifier.fillMaxWidth().weight(1f),
                onRelease = {
                    web = null
                    it.destroy()
                },
            )
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun createWeb(): WebView = WebView(this).apply {
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.allowFileAccess = false
        settings.allowContentAccess = false
        settings.useWideViewPort = true
        settings.loadWithOverviewMode = true
        webChromeClient = object : WebChromeClient() {
            override fun onProgressChanged(view: WebView?, newProgress: Int) {
                // apply 的接收者是 WebView，直接写 progress 会命中 WebView.progress（只读）
                this@LoginActivity.loadProgress = newProgress
            }
        }
        webViewClient = object : WebViewClient() {
            override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean =
                intercept(view, request.url, request.isForMainFrame)

            override fun onPageFinished(view: WebView?, url: String?) {
                pageUrl = url
                consider()
            }

            override fun doUpdateVisitedHistory(view: WebView?, url: String?, isReload: Boolean) {
                pageUrl = url
                consider()
            }
        }
    }

    private fun start(view: WebView) {
        val cm = CookieManager.getInstance()
        cm.setAcceptCookie(true)
        cm.setAcceptThirdPartyCookies(view, true)
        val go = {
            if (!done && !isDestroyed) {
                armed = true
                view.loadUrl(page)
                main.removeCallbacks(poll)
                main.post(poll)
            }
        }
        if (fresh) clearWebData(go) else go()
    }

    private fun onSite(host: String?): Boolean {
        val h = host?.lowercase() ?: return false
        return h == domain || h.endsWith(".$domain")
    }

    /** 主框架只在登录域及子域内走 https；外部 App 的 scheme 交给系统，其它拦截 */
    private fun intercept(view: WebView, uri: Uri, mainFrame: Boolean): Boolean {
        when (val scheme = uri.scheme?.lowercase()) {
            "http", "https" -> {
                if (!mainFrame) return false
                if (!onSite(uri.host)) {
                    Toast.makeText(this, "已拦截非官方页面：${uri.host.orEmpty()}", Toast.LENGTH_SHORT).show()
                    return true
                }
                if (scheme == "https") return false
                view.loadUrl(uri.buildUpon().scheme("https").build().toString())
                return true
            }
            "about" -> return false
            null, "javascript", "file", "content", "data", "blob" -> return true
            else -> {
                openExternal(uri)
                return true
            }
        }
    }

    private fun openExternal(uri: Uri) {
        val ok = runCatching {
            val intent = if (uri.scheme.equals("intent", true)) {
                Intent.parseUri(uri.toString(), Intent.URI_INTENT_SCHEME).apply {
                    component = null
                    selector = null
                    flags = flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                        Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION).inv()
                }
            } else {
                Intent(Intent.ACTION_VIEW, uri)
            }
            startActivity(intent.addCategory(Intent.CATEGORY_BROWSABLE))
        }.isSuccess
        if (!ok) Toast.makeText(this, "没有可以打开该链接的应用", Toast.LENGTH_SHORT).show()
    }

    /** 只读登录域及子域的 Cookie */
    private fun readCookies(): String {
        val cm = CookieManager.getInstance()
        val current = pageUrl?.let(Uri::parse)?.takeIf { it.scheme == "https" && onSite(it.host) }?.toString()
        val urls = listOfNotNull("https://$domain", "https://www.$domain", current)
        return urls.mapNotNull { cm.getCookie(it) }.filter { it.isNotBlank() }.joinToString("; ")
    }

    private fun consider() {
        if (!armed || done || checking) return
        val picked = Native.loginPick(id, readCookies())
        if (picked.isEmpty()) return
        // 同一组登录 Cookie 校验失败（如断网或尚未真正登录）时每 5 秒重试一次
        val now = SystemClock.elapsedRealtime()
        if (picked == lastPicked && now - triedAt < 5000) return
        lastPicked = picked
        triedAt = now
        checking = true
        status = "正在校验登录…"
        Native.loginCheck(id, picked) { kind, _ -> main.post { checked(picked, kind == Native.FINAL) } }
    }

    private fun checked(picked: String, ok: Boolean) {
        checking = false
        if (done || isDestroyed) return
        if (!ok) {
            status = "登录校验未通过，请继续完成登录"
            return
        }
        Native.loginSet(id, picked)
        if (!Native.loginHas(id)) {
            status = null
            if (!saveWarned) {
                saveWarned = true
                Toast.makeText(this, "登录没有保存成功", Toast.LENGTH_LONG).show()
            }
            return
        }
        done = true
        main.removeCallbacks(poll)
        web?.apply {
            stopLoading()
            loadUrl("about:blank")
        }
        // 凭据只保留在 accounts.json
        clearWebData()
        Toast.makeText(this, "${titleText}已登录", Toast.LENGTH_SHORT).show()
        finish()
    }

    companion object {
        const val EXTRA_ID = "id"
        private var openedAt = 0L

        /** 连点只开一个登录页 */
        fun open(ctx: Context, id: String) {
            val now = SystemClock.elapsedRealtime()
            if (now - openedAt < 1000) return
            openedAt = now
            ctx.startActivity(Intent(ctx, LoginActivity::class.java).putExtra(EXTRA_ID, id))
        }

        /** 清掉 WebView 的 Cookie 与网页存储，须在主线程调用；then 在清完 Cookie 后于主线程回调 */
        fun clearWebData(then: () -> Unit = {}) {
            WebStorage.getInstance().deleteAllData()
            val cm = CookieManager.getInstance()
            cm.removeAllCookies {
                cm.flush()
                then()
            }
        }
    }
}
