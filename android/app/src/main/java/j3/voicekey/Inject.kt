package j3.voicekey

import android.content.ClipData
import android.content.ClipboardManager
import android.os.Bundle
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT
import android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT
import android.view.accessibility.AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE

/** 在开始说话时的光标处替换成识别文本：每次以当时的原文为底整体写回 */
class Typer(private val node: AccessibilityNodeInfo) {
    private val base: String
    private val start: Int
    private val end: Int

    init {
        val raw = node.text?.toString().orEmpty()
        // Telegram 空输入框把占位文字当正文上报，且此时不给 hintText，只能以输入连接里的真实正文为准
        val empty = node.isShowingHintText || raw == node.hintText?.toString() || VoiceService.instance?.editorEmpty() == true
        val t = if (empty) "" else raw
        var s = node.textSelectionStart
        var e = node.textSelectionEnd
        if (s !in 0..t.length || e !in 0..t.length) {
            s = t.length
            e = t.length
        }
        base = t
        start = minOf(s, e)
        end = maxOf(s, e)
    }

    fun update(text: String): Boolean {
        if (!node.refresh()) return false
        val full = base.substring(0, start) + text + base.substring(end)
        val ok = node.performAction(
            AccessibilityNodeInfo.ACTION_SET_TEXT,
            Bundle().apply { putCharSequence(ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, full) },
        )
        if (ok) {
            val c = start + text.length
            node.performAction(
                AccessibilityNodeInfo.ACTION_SET_SELECTION,
                Bundle().apply {
                    putInt(ACTION_ARGUMENT_SELECTION_START_INT, c)
                    putInt(ACTION_ARGUMENT_SELECTION_END_INT, c)
                },
            )
        }
        return ok
    }
}

object Inject {
    /** 写入失败时走输入连接提交，再不行走剪贴板粘贴，仍失败则只复制 */
    fun insert(svc: VoiceService, node: AccessibilityNodeInfo?, text: String) {
        if (node != null && Typer(node).update(text)) return
        if (svc.commit(text)) return
        svc.getSystemService(ClipboardManager::class.java).setPrimaryClip(ClipData.newPlainText("VoiceKey", text))
        if (node == null || !node.refresh() || !node.performAction(AccessibilityNodeInfo.ACTION_PASTE)) {
            svc.hud.info("已复制，长按输入框粘贴")
        }
    }
}
