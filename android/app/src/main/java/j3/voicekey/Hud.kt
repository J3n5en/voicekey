package j3.voicekey

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Canvas
import android.graphics.LinearGradient
import android.graphics.Paint
import android.graphics.PixelFormat
import android.graphics.Shader
import android.graphics.drawable.GradientDrawable
import android.os.Handler
import android.os.Looper
import android.text.TextUtils
import android.view.Gravity
import android.view.View
import android.view.WindowManager
import android.widget.LinearLayout
import android.widget.TextView

/** 屏幕顶部浮层：单渠道显示实时文字，多渠道显示候选列表（可点） */
@SuppressLint("SetTextI18n")
class Hud(private val svc: VoiceService) {
    private val wm = svc.getSystemService(WindowManager::class.java)
    private val dp = svc.resources.displayMetrics.density
    private val main = Handler(Looper.getMainLooper())
    private val hideRun = Runnable { detach() }
    private val title = label(13f, DIM)
    private val wave = Wave(svc)
    private val body = label(16f, WHITE).apply { maxLines = 6; ellipsize = TextUtils.TruncateAt.START }
    private val list = LinearLayout(svc).apply { orientation = LinearLayout.VERTICAL }
    private val root = LinearLayout(svc).apply {
        orientation = LinearLayout.VERTICAL
        setPadding(px(16), px(12), px(16), px(14))
        background = GradientDrawable().apply { cornerRadius = 22 * dp; setColor(BG) }
        addView(LinearLayout(svc).apply {
            gravity = Gravity.CENTER_VERTICAL
            addView(title, LinearLayout.LayoutParams(0, -2, 1f))
            addView(wave, LinearLayout.LayoutParams(px(64), px(20)))
        })
        addView(body, LinearLayout.LayoutParams(-1, -2).apply { topMargin = px(6) })
        addView(list, LinearLayout.LayoutParams(-1, -2))
    }
    private val lp = WindowManager.LayoutParams(
        0, WindowManager.LayoutParams.WRAP_CONTENT,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE,
        PixelFormat.TRANSLUCENT,
    ).apply { gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL }
    private var attached = false

    private fun px(v: Int) = (v * dp).toInt()

    private fun label(size: Float, color: Int) = TextView(svc).apply {
        textSize = size
        setTextColor(color)
    }

    fun level(v: Float) = wave.push(v)

    fun update() {
        val s = svc.session
        if (!s.active) return detach()
        main.removeCallbacks(hideRun)
        wave.visibility = if (s.recording) View.VISIBLE else View.INVISIBLE
        if (!s.picking) {
            val r = s.rows[0]
            title.text = "${r.ch.short} · ${if (s.recording) "聆听中" else "识别中"}"
            body.visibility = View.VISIBLE
            body.text = r.text.ifEmpty { if (s.recording) "请说话…" else "…" }
            list.removeAllViews()
        } else {
            title.text = if (s.recording) "多渠道 · 聆听中，点一条结束并上屏" else "点一条上屏 · 音量下键上屏高亮 · 音量上键切换"
            body.visibility = View.GONE
            rows(s)
        }
        attach(touchable = s.picking)
    }

    private fun rows(s: Session) {
        if (list.childCount != s.rows.size + 1) {
            list.removeAllViews()
            s.rows.indices.forEach { i ->
                list.addView(LinearLayout(svc).apply {
                    orientation = LinearLayout.VERTICAL
                    setPadding(px(10), px(8), px(10), px(8))
                    addView(label(12f, DIM))
                    addView(label(15f, WHITE).apply { maxLines = 3; ellipsize = TextUtils.TruncateAt.START })
                    setOnClickListener { svc.session.choose(i) }
                }, LinearLayout.LayoutParams(-1, -2).apply { topMargin = px(4) })
            }
            list.addView(label(14f, DIM).apply {
                text = "取消"
                gravity = Gravity.END
                setPadding(px(10), px(10), px(4), 0)
                setOnClickListener { svc.session.abort(null) }
            })
        }
        s.rows.forEachIndexed { i, r ->
            val v = list.getChildAt(i) as LinearLayout
            val state = when (r.state) {
                Session.State.Listen -> ""
                Session.State.Wait -> " · 识别中"
                Session.State.Final -> r.ms?.let { " · ${it}ms" }.orEmpty()
                Session.State.Error -> " · 失败"
            }
            (v.getChildAt(0) as TextView).text = "${i + 1}  ${r.ch.short}$state"
            (v.getChildAt(1) as TextView).apply {
                text = r.text.ifEmpty { "…" }
                setTextColor(if (r.state == Session.State.Error) DIM else WHITE)
            }
            v.background = if (i == s.sel) GradientDrawable().apply { cornerRadius = 12 * dp; setColor(SEL) } else null
        }
    }

    fun error(msg: String) = flash("VoiceKey", msg, 2500)

    fun info(msg: String) = flash("VoiceKey", msg, 1500)

    private fun flash(head: String, msg: String, ms: Long) {
        title.text = head
        body.visibility = View.VISIBLE
        body.text = msg
        list.removeAllViews()
        wave.visibility = View.INVISIBLE
        attach(touchable = false)
        main.removeCallbacks(hideRun)
        main.postDelayed(hideRun, ms)
    }

    private fun attach(touchable: Boolean) {
        val m = svc.resources.displayMetrics
        lp.width = minOf(m.widthPixels - px(24), px(440))
        lp.y = px(48)
        val f = WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE
        lp.flags = if (touchable) f else f or WindowManager.LayoutParams.FLAG_NOT_TOUCHABLE
        if (attached) wm.updateViewLayout(root, lp) else wm.addView(root, lp)
        attached = true
    }

    fun detach() {
        main.removeCallbacks(hideRun)
        if (attached) wm.removeView(root)
        attached = false
    }

    private class Wave(ctx: Context) : View(ctx) {
        private val levels = FloatArray(14)
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        private val dp = ctx.resources.displayMetrics.density

        fun push(v: Float) {
            System.arraycopy(levels, 1, levels, 0, levels.size - 1)
            levels[levels.size - 1] = v
            invalidate()
        }

        override fun onSizeChanged(w: Int, h: Int, ow: Int, oh: Int) {
            paint.shader = LinearGradient(0f, 0f, w.toFloat(), 0f, intArrayOf(0xFF22C3FF.toInt(), 0xFF7B5CFF.toInt(), 0xFFFF3D8B.toInt()), null, Shader.TileMode.CLAMP)
        }

        override fun onDraw(c: Canvas) {
            val step = width / levels.size.toFloat()
            val bar = step * 0.55f
            levels.forEachIndexed { i, v ->
                val h = maxOf(2 * dp, v * height)
                val x = i * step + (step - bar) / 2
                c.drawRoundRect(x, (height - h) / 2, x + bar, (height + h) / 2, bar / 2, bar / 2, paint)
            }
        }
    }

    private companion object {
        const val BG = 0xF0171A2E.toInt()
        const val SEL = 0x337B5CFF
        const val WHITE = 0xFFFFFFFF.toInt()
        const val DIM = 0x99FFFFFF.toInt()
    }
}
