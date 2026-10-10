package j3.voicekey

/** crates/core 的 JNI 接口，实现见 android/rust */
object Native {
    const val PARTIAL = 0
    const val FINAL = 1
    const val ERROR = 2

    init {
        System.loadLibrary("voicekey")
    }

    /** 在 Rust 工作线程上回调；每个会话恰好一次 FINAL 或 ERROR */
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
}
