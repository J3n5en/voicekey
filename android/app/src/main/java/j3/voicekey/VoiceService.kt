package j3.voicekey

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo

/** 不占用输入法：无障碍服务找到当前输入框写入文字，提供悬浮球与长按音量下键触发 */
class VoiceService : AccessibilityService() {
    lateinit var session: Session
        private set
    lateinit var hud: Hud
        private set
    private lateinit var bubble: Bubble
    private val main = Handler(Looper.getMainLooper())
    private val check = Runnable { refresh() }
    private var volDown = false
    private var volHeld = false
    private val volLong = Runnable {
        volHeld = true
        session.holdStart()
    }

    override fun onServiceConnected() {
        session = Session(this)
        hud = Hud(this)
        bubble = Bubble(this)
        instance = this
        MicService.start(this)
        refresh()
    }

    override fun onAccessibilityEvent(e: AccessibilityEvent) {
        main.removeCallbacks(check)
        main.postDelayed(check, 150)
    }

    override fun onInterrupt() {}

    override fun onDestroy() {
        instance = null
        main.removeCallbacksAndMessages(null)
        if (::session.isInitialized) {
            session.abort(null)
            bubble.show(false)
            hud.detach()
        }
        super.onDestroy()
    }

    fun focusedInput(): AccessibilityNodeInfo? = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)?.takeIf { it.isEditable }

    /** 微信等会对无障碍隐藏控件树，拿不到输入框时以键盘是否弹出为准 */
    fun typing(): Boolean = focusedInput() != null || windows.any { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }

    /** 微信等拿不到输入框节点时，经系统给无障碍服务的输入连接提交文字（Android 13+） */
    fun commit(text: String): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        val im = inputMethod ?: return false
        if (!im.currentInputStarted) return false
        val ic = im.currentInputConnection ?: return false
        ic.commitText(text, 1, null)
        return true
    }

    fun editorEmpty(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        val im = inputMethod ?: return false
        if (!im.currentInputStarted) return false
        return im.currentInputConnection?.getSurroundingText(1, 1, 0)?.text?.isEmpty() == true
    }

    fun refresh() {
        if (instance != this) return
        bubble.show(App.prefs.bubble && (App.prefs.bubbleAlways || session.active || typing()))
    }

    fun onSessionChanged() {
        bubble.active = session.recording
        hud.update()
        refresh()
    }

    fun onLevel(v: Float) {
        bubble.level = v
        hud.level(v)
    }

    override fun onKeyEvent(e: KeyEvent): Boolean {
        if (!App.prefs.volumeKey) return false
        if (e.keyCode == KeyEvent.KEYCODE_VOLUME_UP) {
            if (!session.picking || session.recording) return false
            if (e.action == KeyEvent.ACTION_UP) session.next()
            return true
        }
        if (e.keyCode != KeyEvent.KEYCODE_VOLUME_DOWN) return false
        when (e.action) {
            KeyEvent.ACTION_DOWN -> {
                if (e.repeatCount > 0) return volDown
                if (!session.active && !typing()) return false
                volDown = true
                volHeld = false
                session.prewarm()
                main.postDelayed(volLong, 300)
                return true
            }
            KeyEvent.ACTION_UP -> {
                if (!volDown) return false
                volDown = false
                main.removeCallbacks(volLong)
                when {
                    volHeld -> session.holdEnd()
                    session.picking -> session.choose(session.sel)
                    session.active -> session.tap()
                    else -> getSystemService(AudioManager::class.java).adjustSuggestedStreamVolume(
                        AudioManager.ADJUST_LOWER, AudioManager.USE_DEFAULT_STREAM_TYPE, AudioManager.FLAG_SHOW_UI,
                    )
                }
                return true
            }
        }
        return false
    }

    companion object {
        var instance: VoiceService? = null
            private set

        fun enabled(ctx: Context): Boolean {
            val list = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
            return list.split(':').any { it.equals("${ctx.packageName}/${VoiceService::class.java.name}", true) }
        }
    }
}
