package j3.voicekey

import android.content.Context
import android.content.SharedPreferences

class Prefs(ctx: Context) {
    val sp: SharedPreferences = ctx.getSharedPreferences("settings", Context.MODE_PRIVATE)

    /** null 为多渠道（说完挑选） */
    var channel: Channel?
        get() = sp.getString("channel", null).let { if (it == ALL) null else Channel.of(it) ?: Channel.Doubao }
        set(v) = sp.edit().putString("channel", v?.id ?: ALL).apply()

    /** 多渠道模式下同时识别的渠道，至少 2 个 */
    var multi: List<Channel>
        get() {
            val ids = sp.getStringSet("multi", null) ?: return Channel.online
            return Channel.entries.filter { it.id in ids }.takeIf { it.size >= 2 } ?: Channel.online
        }
        set(v) = sp.edit().putStringSet("multi", v.map { it.id }.toSet()).apply()

    var lastPick: Channel?
        get() = Channel.of(sp.getString("lastPick", null))
        set(v) = sp.edit().putString("lastPick", v?.id).apply()

    /** 点按说话时静音多少秒自动结束 */
    var silence: Float
        get() = sp.getFloat("silence", 1.5f).coerceIn(1f, 5f)
        set(v) = sp.edit().putFloat("silence", v).apply()

    var streaming: Boolean
        get() = sp.getBoolean("streaming", true)
        set(v) = sp.edit().putBoolean("streaming", v).apply()

    var volumeKey: Boolean
        get() = sp.getBoolean("volumeKey", true)
        set(v) = sp.edit().putBoolean("volumeKey", v).apply()

    var bubble: Boolean
        get() = sp.getBoolean("bubble", true)
        set(v) = sp.edit().putBoolean("bubble", v).apply()

    /** 关闭时只在输入框聚焦时显示悬浮球 */
    var bubbleAlways: Boolean
        get() = sp.getBoolean("bubbleAlways", false)
        set(v) = sp.edit().putBoolean("bubbleAlways", v).apply()

    var bubbleX: Int
        get() = sp.getInt("bubbleX", -1)
        set(v) = sp.edit().putInt("bubbleX", v).apply()

    var bubbleY: Int
        get() = sp.getInt("bubbleY", -1)
        set(v) = sp.edit().putInt("bubbleY", v).apply()

    private companion object {
        const val ALL = "all"
    }
}
