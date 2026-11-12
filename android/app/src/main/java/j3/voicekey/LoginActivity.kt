package j3.voicekey

import android.annotation.SuppressLint
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.webkit.CookieManager
import android.webkit.WebChromeClient
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
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView

/** 用系统 WebView 打开官方登录页，Cookie 齐全后写入 accounts.json */
class LoginActivity : ComponentActivity() {
    private val main = Handler(Looper.getMainLooper())
    private var id = ""
    private var page = ""
    private var domain = ""
    private var titleText = "登录"
    private var pageUrl: String? = null
    private var armed = false
    private var done = false
    private var saveWarned = false
    private var loadProgress by mutableIntStateOf(0)

    private val poll = object : Runnable {
        override fun run() {
            if (done) return
            consider()
            if (!done) main.postDelayed(this, 1000)
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
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
                    Text("在页面中完成登录，成功后自动返回", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
                TextButton({
                    done = true
                    main.removeCallbacks(poll)
                    finish()
                }) { Text("取消") }
            }
            if (shown in 1..99) LinearProgressIndicator({ shown / 100f }, Modifier.fillMaxWidth())
            AndroidView(
                factory = { createWeb().also(::startFresh) },
                modifier = Modifier.fillMaxWidth().weight(1f),
                onRelease = { it.destroy() },
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

    private fun startFresh(view: WebView) {
        val cm = CookieManager.getInstance()
        cm.setAcceptCookie(true)
        cm.setAcceptThirdPartyCookies(view, true)
        cm.removeAllCookies {
            main.post {
                if (done || isDestroyed) return@post
                armed = true
                view.loadUrl(page)
                main.removeCallbacks(poll)
                main.post(poll)
            }
        }
    }

    private fun readCookies(): String {
        val cm = CookieManager.getInstance()
        val urls = listOfNotNull("https://$domain", "https://www.$domain", pageUrl)
        return urls.mapNotNull { cm.getCookie(it) }.filter { it.isNotBlank() }.joinToString("; ")
    }

    private fun consider() {
        if (!armed || done) return
        val raw = readCookies()
        if (!Native.loginSatisfied(id, raw)) return
        done = true
        main.removeCallbacks(poll)
        Native.loginSet(id, raw)
        if (!Native.loginHas(id)) {
            done = false
            if (!saveWarned) {
                saveWarned = true
                Toast.makeText(this, "登录没有保存成功", Toast.LENGTH_LONG).show()
            }
            main.post(poll)
            return
        }
        Toast.makeText(this, "${titleText}已登录", Toast.LENGTH_SHORT).show()
        finish()
    }

    companion object {
        const val EXTRA_ID = "id"
    }
}
