@file:Suppress("UNUSED_PARAMETER")

package j3.voicekey

import android.view.accessibility.AccessibilityNodeInfo
import android.content.Context

enum class Channel(val id: String, val title: String, val short: String, val ready: Boolean = true) {
    A("a", "A", "A"), B("b", "B", "B"), C("c", "C", "C"), D("d", "D", "D"),
    E("e", "E", "E"), F("f", "F", "F"), G("g", "G", "G"), H("h", "H", "H"), I("i", "I", "I")
    ;
    companion object {
        val online = entries.take(3)
        val Doubao = A
        fun of(id: String?) = entries.firstOrNull { it.id == id }
    }
}

object Keys {
    val DEFAULT = listOf(24)
    fun name(keys: List<Int>) = keys.joinToString("+")
}

object App { var prefs = Prefs(Context()) }

class Hud {
    val errors = mutableListOf<String>()
    val infos = mutableListOf<String>()
    fun error(text: String) { errors += text }
    fun info(text: String) { infos += text }
}

class VoiceService {
    val hud = Hud()
    val inserted = mutableListOf<String>()
    var insertOk = true
    var sends = 0
    var changes = 0
    fun focusedInput() = AccessibilityNodeInfo()
    fun onSessionChanged() { changes++ }
    fun onLevel(value: Float) {}
    fun send(node: AccessibilityNodeInfo?) { sends++ }
}

class Recorder(onPcm: (FloatArray, Int) -> Unit, onLevel: (Float) -> Unit, onSilenced: () -> Unit) {
    fun stop() {}
    companion object { const val RATE = 16_000 }
}

object MicService { fun start(svc: VoiceService) {} }
class Typer(node: AccessibilityNodeInfo) { fun update(text: String) = false }
object Inject {
    fun insert(svc: VoiceService, node: AccessibilityNodeInfo?, text: String): Boolean {
        svc.inserted += text
        return svc.insertOk
    }
}

/**
 * 保留释放后的监听器，以验证 free 不取消识别、晚到事件由真实 Session 的状态与代际校验丢弃。
 *
 * Listeners survive handle release: free does not cancel recognition, so the real Session
 * must reject late events using its terminal-state and generation checks.
 */
object Native {
    const val PARTIAL = 0
    const val FINAL = 1
    const val ERROR = 2
    const val RECONNECT = 3
    val listeners = mutableMapOf<Long, (Int, String) -> Unit>()
    val freed = mutableListOf<Long>()
    val finished = mutableListOf<Long>()
    data class JevRequest(val config: String, val texts: List<String>, val callback: (Int, String) -> Unit)
    val jev = mutableListOf<JevRequest>()
    var jevError: String? = "disabled"
    private var nextHandle = 1L

    fun reset() {
        listeners.clear()
        freed.clear()
        finished.clear()
        jev.clear()
        jevError = "disabled"
        nextHandle = 1L
    }

    fun start(id: String, rate: Int, listener: (Int, String) -> Unit): Long {
        val handle = nextHandle++
        listeners[handle] = listener
        return handle
    }
    fun push(handle: Long, pcm: FloatArray, n: Int) {}
    fun finish(handle: Long) { finished += handle }
    fun free(handle: Long) { freed += handle }
    fun prewarm(id: String) {}
    fun jevCheck(config: String) = jevError
    fun jevPick(config: String, texts: Array<String>, listener: (Int, String) -> Unit) {
        jev += JevRequest(config, texts.toList(), listener)
    }
}
