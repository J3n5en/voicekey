package android.os

class Looper {
    companion object {
        fun getMainLooper() = Looper()
    }
}

object SystemClock {
    fun elapsedRealtime() = TestClock.now
}

/**
 * 使用稳定顺序的虚拟主线程队列；移除任务后仍可保留其引用，模拟已出队的晚到回调。
 *
 * A deterministic main-thread queue preserves insertion order. Tests may retain removed tasks
 * to simulate late callbacks that have already left the queue.
 */
object TestClock {
    data class Task(val at: Long, val runnable: Runnable)
    var now = 0L
        private set
    private val tasks = mutableListOf<Task>()

    fun reset() {
        now = 0L
        tasks.clear()
    }

    fun post(runnable: Runnable, delay: Long) {
        tasks += Task(now + delay, runnable)
    }

    fun remove(runnable: Runnable) {
        tasks.removeAll { it.runnable === runnable }
    }

    fun pending() = tasks.toList()

    fun advance(ms: Long) {
        val until = now + ms
        while (true) {
            val task = tasks.minByOrNull { it.at }?.takeIf { it.at <= until } ?: break
            tasks.remove(task)
            now = task.at
            task.runnable.run()
        }
        now = until
    }
}

@Suppress("UNUSED_PARAMETER")
class Handler(looper: Looper) {
    fun post(runnable: Runnable) = TestClock.post(runnable, 0)
    fun postDelayed(runnable: Runnable, delay: Long) = TestClock.post(runnable, delay)
    fun removeCallbacks(runnable: Runnable) = TestClock.remove(runnable)
}
