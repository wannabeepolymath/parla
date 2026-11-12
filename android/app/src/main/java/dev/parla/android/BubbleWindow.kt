package dev.parla.android

import android.content.Context
import android.graphics.*
import android.os.Handler
import android.os.Looper
import android.view.*
import kotlin.math.abs

/** A non-focusable control leaves the originating editor and keyboard focused. */
class BubbleWindow(
    private val context: Context,
    private val onTap: () -> Unit,
    private val onHold: () -> Unit,
    private val onRelease: () -> Unit,
    private val onCancel: () -> Unit,
) {
    private val wm = context.getSystemService(WindowManager::class.java)
    private val density = context.resources.displayMetrics.density
    private val handler = Handler(Looper.getMainLooper())
    private var state = DictationStatus()
    private var scale = 1f
    private var requestedScale = 1f
    private var docked = true
    private var keyboard: ScreenRect? = null
    private var shown = false
    private val params = WindowManager.LayoutParams(dp(56f), dp(56f), WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY,
        WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or WindowManager.LayoutParams.FLAG_NOT_TOUCH_MODAL or
            WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN, PixelFormat.TRANSLUCENT).apply {
        gravity = Gravity.TOP or Gravity.LEFT
        setFitInsetsTypes(0) // Position in display coordinates, then apply safe insets ourselves.
        x = 16; y = 280
    }
    private val view = Pill(context)
    private var downX = 0f
    private var downY = 0f
    private var originX = 0
    private var originY = 0
    private var dragging = false
    private var holding = false
    private var holdMode = false
    private val hold = Runnable { if (!dragging && state.phase != Phase.PROCESSING) { holding = true; holdMode = true; view.performHapticFeedback(HapticFeedbackConstants.LONG_PRESS); onHold() } }

    init {
        view.contentDescription = "parla voice control. Tap to start or finish. Hold to talk. Drag to move."
        view.importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_YES
        view.isClickable = true
        view.setOnClickListener { onTap() }
        view.setOnTouchListener { _, event ->
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downX = event.rawX; downY = event.rawY; originX = params.x; originY = params.y
                    dragging = false; holding = false
                    if (state.phase == Phase.IDLE || state.phase == Phase.ERROR) handler.postDelayed(hold, 350)
                }
                MotionEvent.ACTION_MOVE -> {
                    if (!holding && (abs(event.rawX - downX) > dp(10f) || abs(event.rawY - downY) > dp(10f))) {
                        dragging = true; handler.removeCallbacks(hold)
                        params.x = originX + (event.rawX - downX).toInt()
                        params.y = originY + (event.rawY - downY).toInt()
                        applyPlacement(followKeyboard = false)
                    }
                }
                MotionEvent.ACTION_UP -> {
                    handler.removeCallbacks(hold)
                    if (dragging) {
                        docked = false
                        dragging = false
                        Store.get(context).update { it.copy(settings = it.settings.copy(bubbleX = params.x, bubbleY = params.y, bubbleDocked = false)) }
                    }
                    else if (holding) onRelease()
                    else if ((state.phase == Phase.RECORDING || state.phase == Phase.PROCESSING) && event.x < dp(56f * scale)) onCancel()
                    else if (state.phase != Phase.PROCESSING) { holdMode = false; view.performClick() }
                    holding = false
                }
                MotionEvent.ACTION_CANCEL -> { handler.removeCallbacks(hold); if (holding) onCancel(); holding = false }
            }
            true
        }
    }
    fun show() { updateSize(); applyPlacement(); wm.addView(view, params); shown = true }
    fun configure(settings: Settings) {
        requestedScale = settings.bubbleSize.coerceIn(.7f, 1.5f)
        docked = settings.bubbleDocked
        updateSize()
        if (!dragging) { params.x = settings.bubbleX; params.y = settings.bubbleY }
        view.alpha = settings.bubbleOpacity.coerceIn(.2f, 1f)
        applyPlacement()
        view.invalidate()
    }
    fun render(status: DictationStatus) { state = status; if (state.phase == Phase.IDLE || state.phase == Phase.ERROR) holdMode = false; updateSize(); applyPlacement(); view.contentDescription = "parla: ${status.message}. Tap to start or finish. Hold to talk. Drag to move."; view.invalidate() }
    internal fun placeNearKeyboard(bounds: ScreenRect?) { keyboard = bounds; refreshPlacement() }
    fun refreshPlacement() { updateSize(); applyPlacement(); view.invalidate() }
    fun close() { handler.removeCallbacksAndMessages(null); if (shown) { wm.removeView(view); shown = false } }
    private fun updateSize() {
        val active = state.phase == Phase.RECORDING || state.phase == Phase.PROCESSING
        val width = if (active) { if (holdMode) 160f else 230f } else 56f
        scale = minOf(requestedScale, safeArea().width.toFloat() / dp(width).coerceAtLeast(1), safeArea().height.toFloat() / dp(56f).coerceAtLeast(1))
        params.width = dp(width * scale).coerceAtLeast(1)
        params.height = dp(56f * scale)
    }
    private fun safeArea(): ScreenRect {
        val metrics = wm.currentWindowMetrics
        val insets = metrics.windowInsets.getInsetsIgnoringVisibility(WindowInsets.Type.systemBars() or WindowInsets.Type.displayCutout())
        return ScreenRect(insets.left, insets.top, metrics.bounds.width() - insets.right, metrics.bounds.height() - insets.bottom)
    }
    private fun applyPlacement(followKeyboard: Boolean = docked && !dragging) {
        val origin = wm.currentWindowMetrics.bounds
        val relativeKeyboard = if (followKeyboard) keyboard?.let {
            ScreenRect(it.left - origin.left, it.top - origin.top, it.right - origin.left, it.bottom - origin.top)
        } else null
        val position = BubblePlacement.place(params.x, params.y, params.width, params.height, safeArea(), relativeKeyboard, dp(8f))
        params.x = position.x; params.y = position.y
        if (shown) wm.updateViewLayout(view, params)
    }
    private fun dp(value: Float) = (value * density).toInt()

    private inner class Pill(context: Context) : View(context) {
        private val paint = Paint(Paint.ANTI_ALIAS_FLAG)
        init { elevation = dp(2f).toFloat(); setLayerType(LAYER_TYPE_SOFTWARE, null) }
        override fun performClick(): Boolean = super.performClick()
        private fun icon(canvas: Canvas, resource: Int, x: Float, y: Float, side: Float) {
            context.getDrawable(resource)?.let { drawable ->
                drawable.setBounds(x.toInt(), y.toInt(), (x + side).toInt(), (y + side).toInt())
                drawable.draw(canvas)
            }
        }
        override fun onDraw(canvas: Canvas) {
            super.onDraw(canvas)
            val unit = density * scale
            val h = 56f * unit
            val active = state.phase == Phase.RECORDING || state.phase == Phase.PROCESSING
            paint.style = Paint.Style.FILL
            paint.clearShadowLayer()
            paint.color = Color.rgb(247, 235, 255)
            if (!active) {
                canvas.drawRoundRect(0f, 0f, h, h, 16f * unit, 16f * unit, paint)
                icon(canvas, if (state.phase == Phase.ERROR) R.drawable.ic_retry_bubble else R.drawable.ic_parla_mark, 14f * unit, 14f * unit, 28f * unit)
                return
            }
            val ptt = holdMode
            if (ptt) {
                if (state.phase == Phase.RECORDING) paint.color = Color.rgb(108, 53, 140)
                canvas.drawRoundRect(0f, 0f, width.toFloat(), h, 32f * unit, 32f * unit, paint)
            } else {
                canvas.drawRoundRect(0f, 0f, h, h, 32f * unit, 32f * unit, paint)
                canvas.drawRoundRect(62f * unit, 0f, 168f * unit, h, 32f * unit, 32f * unit, paint)
                paint.color = if (state.phase == Phase.RECORDING) Color.rgb(108, 53, 140) else Color.rgb(247, 235, 255)
                canvas.drawRoundRect(174f * unit, 0f, 230f * unit, h, 32f * unit, 32f * unit, paint)
                icon(canvas, R.drawable.ic_close, 14f * unit, 14f * unit, 28f * unit)
                if (state.phase == Phase.RECORDING) icon(canvas, R.drawable.ic_check, 188f * unit, 14f * unit, 28f * unit)
            }
            val center = if (ptt) 63f * unit else 115f * unit
            if (state.phase == Phase.PROCESSING) {
                val loaderCenter = if (ptt) 130f * unit else 202f * unit
                canvas.save()
                canvas.rotate((android.os.SystemClock.uptimeMillis() % 1000) * .36f, loaderCenter, h / 2f)
                icon(canvas, R.drawable.ic_bar_dictation_loader, loaderCenter - 14f * unit, 14f * unit, 28f * unit)
                canvas.restore()
                postInvalidateDelayed(40)
            } else if (ptt) {
                icon(canvas, R.drawable.ic_bar_recording, 120f * unit, 16f * unit, 24f * unit)
            }
            run {
                paint.color = if (state.phase == Phase.PROCESSING) Color.rgb(202, 190, 208) else if (ptt) Color.rgb(247, 235, 255) else Color.rgb(26, 26, 26)
                paint.strokeWidth = 3f * unit
                paint.strokeCap = Paint.Cap.ROUND
                val level = state.level.coerceIn(0f, 1f)
                for (index in 0..8) {
                    val amplitude = (6f + (1f - abs(index - 4) / 5f) * (8f + level * 18f)) * unit
                    val x = center + (index - 4) * 6f * unit
                    canvas.drawLine(x, h / 2f - amplitude / 2, x, h / 2f + amplitude / 2, paint)
                }
            }
        }
    }
}
