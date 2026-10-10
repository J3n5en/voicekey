package j3.voicekey

import android.annotation.SuppressLint
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PixelFormat
import android.view.Gravity
import android.view.HapticFeedbackConstants
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import kotlin.math.hypot

/** 悬浮球：点按说话（静音自动结束），长按说话松开结束，拖动换位置 */
@SuppressLint("ViewConstructor", "ClickableViewAccessibility")
class Bubble(private val svc: VoiceService) : View(svc) {
    private val wm = svc.getSystemService(WindowManager::class.java)
    private val dp = resources.displayMetrics.density
    private val size = (52 * dp).toInt()
    private val icon = svc.getDrawable(R.drawable.ic_wave)!!
    private val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply { color = 0xE6171A2E.toInt() }
    private val ring = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        style = Paint.Style.STROKE
        strokeWidth = 3 * dp
        color = 0xFFFF3D8B.toInt()
    }
    private val lp = WindowManager.LayoutParams(
        size, size,
        WindowManager.LayoutParams.TYPE_ACCESSIBILITY_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_LAYOUT_NO_LIMITS,
        PixelFormat.TRANSLUCENT,
    ).apply { gravity = Gravity.TOP or Gravity.START }
    private var added = false
    private var downX = 0f
    private var downY = 0f
    private var startX = 0
    private var startY = 0
    private var dragging = false
    private var held = false
    private val longPress = Runnable {
        held = true
        performHapticFeedback(HapticFeedbackConstants.LONG_PRESS)
        svc.session.holdStart()
    }

    var level = 0f
        set(v) {
            field = v
            invalidate()
        }

    var active = false
        set(v) {
            if (field == v) return
            field = v
            if (!v) level = 0f
            invalidate()
        }

    fun show(on: Boolean) {
        if (on == added) return
        if (on) {
            place()
            wm.addView(this, lp)
        } else {
            removeCallbacks(longPress)
            wm.removeView(this)
        }
        added = on
    }

    private fun place() {
        val m = resources.displayMetrics
        val p = App.prefs
        lp.x = if (p.bubbleX >= 0) p.bubbleX.coerceIn(0, m.widthPixels - size) else m.widthPixels - size - (8 * dp).toInt()
        lp.y = if (p.bubbleY >= 0) p.bubbleY.coerceIn(0, m.heightPixels - size) else (m.heightPixels * 0.4f).toInt()
    }

    override fun onDraw(c: Canvas) {
        val r = width / 2f
        c.drawCircle(r, r, r - 3 * dp, bg)
        if (active) {
            ring.alpha = (120 + 135 * level).toInt()
            c.drawCircle(r, r, r - 2 * dp, ring)
        }
        val pad = (14 * dp).toInt()
        icon.setBounds(pad, pad, width - pad, height - pad)
        icon.draw(c)
    }

    override fun onTouchEvent(e: MotionEvent): Boolean {
        when (e.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                downX = e.rawX
                downY = e.rawY
                startX = lp.x
                startY = lp.y
                dragging = false
                held = false
                svc.session.prewarm()
                postDelayed(longPress, 300)
            }
            MotionEvent.ACTION_MOVE -> {
                val dx = e.rawX - downX
                val dy = e.rawY - downY
                if (!held && !dragging && hypot(dx, dy) > 8 * dp) {
                    dragging = true
                    removeCallbacks(longPress)
                }
                if (dragging) {
                    lp.x = startX + dx.toInt()
                    lp.y = startY + dy.toInt()
                    wm.updateViewLayout(this, lp)
                }
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                removeCallbacks(longPress)
                when {
                    held -> svc.session.holdEnd()
                    dragging -> {
                        App.prefs.bubbleX = lp.x
                        App.prefs.bubbleY = lp.y
                    }
                    e.actionMasked == MotionEvent.ACTION_UP -> svc.session.tap()
                }
            }
        }
        return true
    }
}
