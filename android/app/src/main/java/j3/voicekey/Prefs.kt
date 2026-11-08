package j3.voicekey

import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject

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

    /** 候选框各渠道上屏次数，次数多的排前 */
    fun pickCount(ch: Channel) = sp.getInt("pickCount.${ch.id}", 0)

    fun countPick(ch: Channel) = sp.edit().putInt("pickCount.${ch.id}", pickCount(ch) + 1).apply()

    /** Jev 智能选择：off / official / yce，仅多渠道模式生效 */
    var jevMode: String
        get() = sp.getString("jevMode", "off") ?: "off"
        set(v) = sp.edit().putString("jevMode", v).apply()

    var jevKey: String
        get() = sp.getString("jevKey", "") ?: ""
        set(v) = sp.edit().putString("jevKey", v).apply()

    var jevEndpoint: String
        get() = sp.getString("jevEndpoint", "") ?: ""
        set(v) = sp.edit().putString("jevEndpoint", v).apply()

    var jevModel: String
        get() = sp.getString("jevModel", "") ?: ""
        set(v) = sp.edit().putString("jevModel", v).apply()

    /** 自定义格式（内部值仍为 yce）：每行 alias|key|endpoint */
    var jevPool: String
        get() = sp.getString("jevPool", "") ?: ""
        set(v) = sp.edit().putString("jevPool", v).apply()

    var jevSelectionThreshold: JevSelectionThreshold
        get() = JevSelectionThreshold.of(sp.getString("jevSelectionThreshold", null))
        set(v) = sp.edit().putString("jevSelectionThreshold", v.id).apply()

    var jevSelectionWaitMs: Int
        get() = JevSelectionTiming.clampWait(sp.getInt("jevSelectionWaitMs", JevSelectionTiming.DEFAULT_WAIT_MS))
        set(v) = sp.edit().putInt("jevSelectionWaitMs", JevSelectionTiming.clampWait(v)).apply()

    fun jevSelectionTiming() = JevSelectionTiming(jevSelectionThreshold, jevSelectionWaitMs)

    /**
     * 只恢复选择时机，不修改模式、密钥及其他 Jev 设置。
     *
     * Restore only selection timing, leaving the mode, credentials, and other Jev settings untouched.
     */
    fun resetJevSelectionTiming() {
        sp.edit()
            .putString("jevSelectionThreshold", JevSelectionThreshold.TwoThirds.id)
            .putInt("jevSelectionWaitMs", JevSelectionTiming.DEFAULT_WAIT_MS)
            .apply()
    }

    /**
     * core jev::Config 的 camelCase JSON；会话传入录音快照，设置页默认使用当前选择时机。
     *
     * Produce camelCase JSON for core jev::Config. Sessions supply a recording snapshot;
     * the settings screen defaults to the current selection timing.
     */
    fun jevConfig(timing: JevSelectionTiming = jevSelectionTiming()): String = JSONObject()
        .put("mode", jevMode)
        .put("key", jevKey)
        .put("endpoint", jevEndpoint)
        .put("model", jevModel)
        .put("pool", jevPool)
        .put("selectionThreshold", timing.threshold.id)
        .put("selectionWaitMs", timing.waitMs)
        .toString()

    /** 点按说话时静音多少秒自动结束 */
    var silence: Float
        get() = sp.getFloat("silence", 1.5f).coerceIn(1f, 5f)
        set(v) = sp.edit().putFloat("silence", v).apply()

    /** 关闭后点按说话只能再点一次结束 */
    var silenceStop: Boolean
        get() = sp.getBoolean("silenceStop", true)
        set(v) = sp.edit().putBoolean("silenceStop", v).apply()

    var streaming: Boolean
        get() = sp.getBoolean("streaming", true)
        set(v) = sp.edit().putBoolean("streaming", v).apply()

    /** 多渠道候选：点一条上屏并发送，长按只上屏；旧的 Jev 自动发送开关已合并到本开关（未写过 pickSend 时回退读旧值） */
    var pickSend: Boolean
        get() = if (sp.contains("pickSend")) sp.getBoolean("pickSend", false) else sp.getBoolean("jevSend", false)
        set(v) = sp.edit().putBoolean("pickSend", v).apply()

    /** 上次自动检查更新的时间（毫秒），用于 12 小时节流 */
    var updateCheckedAt: Long
        get() = sp.getLong("updateCheckedAt", 0L)
        set(v) = sp.edit().putLong("updateCheckedAt", v).apply()

    /** 长按说话开关（沿用旧键名） */
    var volumeKey: Boolean
        get() = sp.getBoolean("volumeKey", true)
        set(v) = sp.edit().putBoolean("volumeKey", v).apply()

    var holdKeys: List<Int>
        get() = sp.getString("holdKeys", null)?.split(',')?.mapNotNull { it.toIntOrNull() }?.takeIf { it.isNotEmpty() } ?: Keys.DEFAULT
        set(v) = sp.edit().putString("holdKeys", v.joinToString(",")).apply()

    val holdName get() = Keys.name(holdKeys)

    var bubble: Boolean
        get() = sp.getBoolean("bubble", true)
        set(v) = sp.edit().putBoolean("bubble", v).apply()

    /** 关闭时只在输入框聚焦时显示悬浮球 */
    var bubbleAlways: Boolean
        get() = sp.getBoolean("bubbleAlways", false)
        set(v) = sp.edit().putBoolean("bubbleAlways", v).apply()

    var bubbleX: Int
        get() = sp.getInt("bubbleX", UNSET)
        set(v) = sp.edit().putInt("bubbleX", v).apply()

    var bubbleY: Int
        get() = sp.getInt("bubbleY", UNSET)
        set(v) = sp.edit().putInt("bubbleY", v).apply()

    companion object {
        const val UNSET = Int.MIN_VALUE
        private const val ALL = "all"
    }
}
