package android.widget

@Suppress("UNUSED_PARAMETER")
class Toast {
    fun show() {}
    companion object {
        const val LENGTH_SHORT = 0
        fun makeText(context: Any, text: String, duration: Int) = Toast()
    }
}
