package j3.voicekey

enum class JevSelectionThreshold(val id: String, private val numerator: Int, private val denominator: Int) {
    Half("half", 1, 2), TwoThirds("twoThirds", 2, 3), All("all", 1, 1);

    /**
     * 参与渠道包含失败项，成功数只包含可用定稿；整数比例向上取整，不受浮点误差影响。
     *
     * Participating channels include failures, while successes include only usable finals.
     * Round the integer ratio upward without floating-point error.
     */
    fun required(participants: Int): Int =
        ((participants.toLong() * numerator + denominator - 1) / denominator).toInt()

    companion object {
        fun of(id: String?) = entries.firstOrNull { it.id == id } ?: TwoThirds
    }
}

data class JevSelectionTiming(
    val threshold: JevSelectionThreshold = JevSelectionThreshold.TwoThirds,
    val waitMs: Int = DEFAULT_WAIT_MS,
) {
    companion object {
        const val DEFAULT_WAIT_MS = 2_500
        const val MIN_WAIT_MS = 500
        const val MAX_WAIT_MS = 5_000

        fun clampWait(ms: Int) = ms.coerceIn(MIN_WAIT_MS, MAX_WAIT_MS)

        /**
         * 编辑框仅接受 0.5 至 5 秒内、符合半秒步长的有限数值，不对无效输入取整或钳制。
         * 非法输入由界面提示并恢复上次保存值，不写入设置。
         *
         * Accept only finite values from 0.5 to 5 seconds in half-second steps, without rounding
         * or clamping invalid input. The UI reports invalid input and restores the last saved
         * value without persisting it.
         */
        fun parseWaitSeconds(text: String): Int? {
            val seconds = text.trim().toDoubleOrNull()?.takeIf { it.isFinite() } ?: return null
            if (seconds !in 0.5..5.0 || (seconds * 2) % 1.0 != 0.0) return null
            return (seconds * 1000).toInt()
        }
    }
}
