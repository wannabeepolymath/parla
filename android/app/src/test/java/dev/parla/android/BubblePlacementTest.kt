package dev.parla.android

import org.junit.Assert.*
import org.junit.Test

class BubblePlacementTest {
    private val area = ScreenRect(12, 24, 400, 800)
    private val keyboard = ScreenRect(0, 500, 412, 820)

    @Test fun docksAboveTheKeyboardWithAGap() {
        assertEquals(BubblePosition(16, 436), BubblePlacement.place(16, 280, 56, 56, area, keyboard, 8))
    }

    @Test fun expandedPillAndRestoredOffScreenCoordinatesStayInsideSafeInsets() {
        assertEquals(BubblePosition(170, 436), BubblePlacement.place(900, 900, 230, 56, area, keyboard, 8))
        assertEquals(BubblePosition(12, 24), BubblePlacement.place(-900, -900, 56, 56, area, null, 8))
    }

    @Test fun missingOrStaleKeyboardBoundsPreserveClampedManualPlacement() {
        for (rect in listOf(null, ScreenRect(0, 900, 400, 1200), ScreenRect(0, 0, 0, 0))) {
            assertEquals(BubblePosition(80, 300), BubblePlacement.place(80, 300, 56, 56, area, rect, 8))
        }
    }

    @Test fun floatingKeyboardAndInsufficientSpaceAreBestEffortAndClamped() {
        assertEquals(BubblePosition(80, 236), BubblePlacement.place(80, 300, 56, 56, area, ScreenRect(100, 300, 350, 600), 8))
        assertEquals(BubblePosition(80, 24), BubblePlacement.place(80, 300, 56, 56, area, ScreenRect(0, 40, 400, 800), 8))
    }

    @Test fun landscapeAndDisplayCutoutsClampTheExpandedControl() {
        assertEquals(BubblePosition(390, 106), BubblePlacement.place(900, 300, 230, 64,
            ScreenRect(40, 16, 620, 360), ScreenRect(0, 180, 640, 360), 10))
    }
}
