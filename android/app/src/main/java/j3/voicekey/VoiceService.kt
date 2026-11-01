package j3.voicekey

import android.accessibilityservice.AccessibilityService
import android.content.Context
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import android.view.KeyCharacterMap
import android.view.KeyEvent
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.view.inputmethod.EditorInfo

/** 不占用输入法：无障碍服务找到当前输入框写入文字，提供悬浮球与长按按键（默认音量下键，可自定义组合）触发 */
class VoiceService : AccessibilityService() {
    lateinit var session: Session
        private set
    lateinit var hud: Hud
        private set
    private lateinit var bubble: Bubble
    private val main = Handler(Looper.getMainLooper())
    private val check = Runnable { refresh() }
    private var chordKeys = App.prefs.holdKeys
    private var chord = Chord(chordKeys)

    /** 设置页录制长按组合：非空时接管按键，录完回调结果；null 表示取消 */
    var recorder: ((List<Int>?) -> Unit)? = null
        set(v) {
            field = v
            recHeld.clear()
            recPeak.clear()
            chord.reset()
        }
    private val recHeld = mutableSetOf<Int>()
    private val recPeak = mutableListOf<Int>()

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

    /** 上屏后发送：发送按钮常在有字后才出现，稍等重试；找不到再走输入框的发送动作或回车 */
    fun send(node: AccessibilityNodeInfo?, tries: Int = 3) {
        main.postDelayed({
            when {
                clickSend(node) -> {}
                tries > 1 -> send(node, tries - 1)
                !editorSend() -> hud.info("没找到发送按钮，已上屏")
            }
        }, 150L * (4 - tries))
    }

    private fun clickSend(node: AccessibilityNodeInfo?): Boolean {
        val root = node?.window?.root ?: rootInActiveWindow ?: return false
        val hit = SEND.firstNotNullOfOrNull { w ->
            root.findAccessibilityNodeInfosByText(w).firstOrNull { n ->
                n.isVisibleToUser && n.isEnabled && !n.isEditable &&
                    listOf(n.text, n.contentDescription).any { it?.toString()?.trim().equals(w, ignoreCase = true) }
            }
        } ?: return false
        var n: AccessibilityNodeInfo? = hit
        while (n != null && !n.isClickable) n = n.parent
        return n?.performAction(AccessibilityNodeInfo.ACTION_CLICK) == true
    }

    private fun editorSend(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        val im = inputMethod ?: return false
        if (!im.currentInputStarted) return false
        val ic = im.currentInputConnection ?: return false
        val action = (im.currentInputEditorInfo?.imeOptions ?: 0) and EditorInfo.IME_MASK_ACTION
        if (action in ACTIONS) {
            ic.performEditorAction(action)
        } else {
            ic.sendKeyEvent(KeyEvent(KeyEvent.ACTION_DOWN, KeyEvent.KEYCODE_ENTER))
            ic.sendKeyEvent(KeyEvent(KeyEvent.ACTION_UP, KeyEvent.KEYCODE_ENTER))
        }
        return true
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
        recorder?.let { return record(it, e) }
        if (!App.prefs.volumeKey) return false
        val keys = App.prefs.holdKeys
        if (keys != chordKeys) {
            chordKeys = keys
            chord = Chord(keys)
        }
        if (e.keyCode == KeyEvent.KEYCODE_VOLUME_UP && e.keyCode !in keys) {
            if (!session.picking || session.recording) return false
            if (e.action == KeyEvent.ACTION_UP) session.next()
            return true
        }
        if (e.action != KeyEvent.ACTION_DOWN && e.action != KeyEvent.ACTION_UP) return false
        val c = chord
        return c.key(e.keyCode, e.action == KeyEvent.ACTION_DOWN, e.repeatCount > 0, { session.active || typing() }) { out ->
            when (out) {
                Chord.Arm -> {
                    session.prewarm()
                    val g = c.gen
                    main.postDelayed({ if (c.fire(g)) session.holdStart() }, 300)
                }
                Chord.Disarm -> {}
                Chord.Release -> session.holdEnd()
                is Chord.Short -> when {
                    out.act && session.picking -> session.choose(session.sel)
                    out.act && session.active -> session.tap()
                    else -> out.replay.forEach {
                        getSystemService(AudioManager::class.java).adjustSuggestedStreamVolume(
                            if (Keys.volume[it] == 1) AudioManager.ADJUST_RAISE else AudioManager.ADJUST_LOWER,
                            AudioManager.USE_DEFAULT_STREAM_TYPE, AudioManager.FLAG_SHOW_UI,
                        )
                    }
                }
            }
        }
    }

    /** 按住一组键，松开任一个时记录本轮按过的全部键；不合法则继续等待。返回键交给系统并取消录制 */
    private fun record(done: (List<Int>?) -> Unit, e: KeyEvent): Boolean {
        val code = e.keyCode
        if (code in Keys.system) {
            if (code == KeyEvent.KEYCODE_BACK && e.action == KeyEvent.ACTION_UP && recHeld.isEmpty()) finishRecord(done, null)
            return false
        }
        when (e.action) {
            KeyEvent.ACTION_DOWN -> if (e.repeatCount == 0 && recHeld.add(code) && code !in recPeak) recPeak += code
            KeyEvent.ACTION_UP -> {
                recHeld -= code
                val keys = recPeak.sortedBy { it !in Keys.modifiers }
                val map = KeyCharacterMap.load(e.deviceId)
                if (Keys.valid(keys) { it !in Keys.modifiers && map.isPrintingKey(it) }) finishRecord(done, keys)
                else recPeak.retainAll(recHeld)
            }
        }
        return true
    }

    private fun finishRecord(done: (List<Int>?) -> Unit, keys: List<Int>?) {
        recorder = null
        if (keys != null) App.prefs.holdKeys = keys
        done(keys)
    }

    companion object {
        var instance: VoiceService? = null
            private set
        private val SEND = listOf("发送", "Send")
        private val ACTIONS = setOf(EditorInfo.IME_ACTION_SEND, EditorInfo.IME_ACTION_GO, EditorInfo.IME_ACTION_SEARCH, EditorInfo.IME_ACTION_DONE)

        fun enabled(ctx: Context): Boolean {
            val list = Settings.Secure.getString(ctx.contentResolver, Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES).orEmpty()
            return list.split(':').any { it.equals("${ctx.packageName}/${VoiceService::class.java.name}", true) }
        }
    }
}
