package dev.parla.android

internal data class ScreenRect(val left: Int, val top: Int, val right: Int, val bottom: Int) {
    val width: Int get() = (right - left).coerceAtLeast(0)
    val height: Int get() = (bottom - top).coerceAtLeast(0)
}
internal data class BubblePosition(val x: Int, val y: Int)

internal object BubblePlacement {
    /** Coordinates share the display origin. No editor contents or keyboard internals are needed. */
    fun place(x: Int, y: Int, width: Int, height: Int, area: ScreenRect, keyboard: ScreenRect?, gap: Int): BubblePosition {
        val maxX = (area.right - width).coerceAtLeast(area.left)
        val maxY = (area.bottom - height).coerceAtLeast(area.top)
        val usableKeyboard = keyboard?.takeIf {
            it.width > 0 && it.height > 0 && it.left < area.right && it.right > area.left &&
                it.top < area.bottom && it.bottom > area.top
        }
        val targetY = usableKeyboard?.let { it.top - height - gap } ?: y
        return BubblePosition(x.coerceIn(area.left, maxX), targetY.coerceIn(area.top, maxY))
    }
}
