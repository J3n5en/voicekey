package j3.voicekey

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import kotlin.concurrent.thread
import kotlin.math.log10
import kotlin.math.max
import kotlin.math.sqrt

/** 16kHz 单声道 f32，20ms 一帧回调；回调在录音线程上 */
@SuppressLint("MissingPermission")
class Recorder(
    private val onPcm: (FloatArray, Int) -> Unit,
    private val onLevel: (Float) -> Unit,
    private val onSilenced: () -> Unit,
) {
    @Volatile private var running = true
    private val rec: AudioRecord
    private val worker: Thread

    init {
        val min = AudioRecord.getMinBufferSize(RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_FLOAT)
        rec = AudioRecord(
            MediaRecorder.AudioSource.VOICE_RECOGNITION, RATE, AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_FLOAT, max(min, FRAME * 4 * 16),
        )
        if (rec.state != AudioRecord.STATE_INITIALIZED) {
            rec.release()
            error("麦克风初始化失败")
        }
        rec.startRecording()
        if (rec.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            rec.release()
            error("麦克风被占用")
        }
        worker = thread(name = "vk-mic") { loop() }
    }

    private fun loop() {
        val buf = FloatArray(FRAME)
        var frames = 0
        var heard = false
        while (running) {
            val n = rec.read(buf, 0, FRAME, AudioRecord.READ_BLOCKING)
            if (n < 0) break
            if (n == 0 || !running) continue
            onPcm(buf, n)
            onLevel(level(buf, n))
            // 系统限制后台录音时只给全零数据，真实麦克风不会出现
            if (!heard && frames < 50) {
                heard = (0 until n).any { buf[it] != 0f }
                if (++frames == 50 && !heard) onSilenced()
            }
        }
    }

    fun stop() {
        running = false
        runCatching { rec.stop() }
        worker.join(500)
        rec.release()
    }

    companion object {
        const val RATE = 16000
        const val FRAME = 320

        /** 与 crates/core audio::level 一致：-50dB..-10dB 映射到 0..1 */
        fun level(buf: FloatArray, n: Int): Float {
            var sum = 0f
            for (i in 0 until n) sum += buf[i] * buf[i]
            val db = 20 * log10(max(sqrt(sum / n), 1e-6f))
            return ((db + 50) / 40).coerceIn(0f, 1f)
        }
    }
}
