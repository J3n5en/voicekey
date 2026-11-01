package j3.voicekey

/** crates/core 的 JNI 接口，实现见 android/rust */
object Native {
    const val PARTIAL = 0
    const val FINAL = 1
    const val ERROR = 2
    /** 连接中断后自动重连，录音不中断；text 为提示文案 */
    const val RECONNECT = 3

    init {
        System.loadLibrary("voicekey")
    }

    /** 在 Rust 工作线程上回调；每个会话恰好一次 FINAL 或 ERROR，重连期间可多次 RECONNECT */
    fun interface Listener {
        fun onEvent(kind: Int, text: String)
    }

    external fun init(dataDir: String)

    /** 引擎名无效返回 0 */
    external fun start(engine: String, sampleRate: Int, listener: Listener): Long
    external fun push(handle: Long, pcm: FloatArray, n: Int)
    external fun finish(handle: Long)

    /** 未 finish 则先 finish，不影响进行中的识别和回调 */
    external fun free(handle: Long)
    external fun prewarm(engine: String)
    external fun wtofflineReady(): Boolean

    /** 成功返回 null */
    external fun wtofflineUnpack(apk: String): String?

    /** 下载地址、字节数、MD5，换行分隔 */
    external fun wtofflineInfo(): String

    /** Jev 智能选择配置自检；可用返回 null，否则返回原因文本 */
    external fun jevCheck(config: String): String?

    /** 恰好回调一次 FINAL 或 ERROR，FINAL 文本为 JSON（Picked：index/alias/ms）；在 Rust 工作线程回调 */
    external fun jevPick(config: String, texts: Array<String>, listener: Listener)

    /** 恰好回调一次 FINAL 或 ERROR，FINAL 文本为 JSON（Tested：index/text/alias/ms/key）；在 Rust 工作线程回调 */
    external fun jevTest(config: String, listener: Listener)
}
