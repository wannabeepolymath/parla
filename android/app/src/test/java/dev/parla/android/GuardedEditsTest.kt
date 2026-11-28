package dev.parla.android

import org.junit.Assert.*
import org.junit.Test

class GuardedEditsTest {
    private val before = EditorSnapshot("dev.test", 4, "editor", "1", "EditText", "Hello world", 6, 11,
        editable = true, enabled = true, focused = true, visible = true, inputType = 1, password = false)
    private val after = before.copy(text = "Hello friend", selectionStart = 12, selectionEnd = 12)
    private fun receipt(raw: String = "frend") = GuardedEdits.receipt(before, "friend", raw, after, 1_000)!!

    @Test fun receiptNeedsTheExactPostWriteFieldAndCaret() {
        assertEquals(6, receipt().start)
        assertEquals(1_000 + GuardedEdits.LIFETIME_MS, receipt().expiresAt)
        // Any other readback is not our write: no authority.
        listOf(after.copy(text = "Hello friend!"), after.copy(selectionStart = 11, selectionEnd = 11), after.copy(selectionStart = 6),
            after.copy(windowId = 5), after.copy(viewId = "other"), after.copy(uniqueId = "2"), after.copy(packageName = "other"),
            after.copy(focused = false), after.copy(password = true))
            .forEach { assertNull(it.toString(), GuardedEdits.receipt(before, "friend", "frend", it, 1_000)) }
        assertNull(GuardedEdits.receipt(before, "", "", before, 1_000))
        assertNull(GuardedEdits.receipt(before.copy(inputType = 0x81), "friend", "frend", after.copy(inputType = 0x81), 1_000))
    }

    @Test fun actionsMatchOnlyTheUnchangedFieldBeforeExpiry() {
        val r = receipt()
        assertTrue(GuardedEdits.matches(r, after, 1_000))
        assertTrue(GuardedEdits.matches(r, after.copy(), r.expiresAt - 1))
        assertFalse(GuardedEdits.matches(r, after, r.expiresAt))
        listOf(after.copy(text = "Hello friends"), after.copy(selectionStart = 6, selectionEnd = 6), after.copy(selectionEnd = 6),
            after.copy(windowId = 9), after.copy(className = "WebView"), after.copy(inputType = 0x20001), after.copy(focused = false),
            after.copy(dataSensitive = true))
            .forEach { assertFalse(it.toString(), GuardedEdits.matches(r, it, 1_000)) }
    }

    @Test fun undoRestoresThePriorFieldAndRestorePutsBackTheOriginalWords() {
        val r = receipt()
        assertEquals(GuardedEdits.Plan("Hello world", 6), GuardedEdits.plan(r, GuardedEdits.Action.undo))
        assertEquals(GuardedEdits.Plan("Hello frend", 11), GuardedEdits.plan(r, GuardedEdits.Action.restoreOriginal))
        val mid = before.copy(text = "ab", selectionStart = 1, selectionEnd = 1)
        val inserted = GuardedEdits.receipt(mid, "XY", "x y", mid.copy(text = "aXYb", selectionStart = 3, selectionEnd = 3), 0)!!
        assertEquals(GuardedEdits.Plan("ab", 1), GuardedEdits.plan(inserted, GuardedEdits.Action.undo))
        assertEquals(GuardedEdits.Plan("ax yb", 4), GuardedEdits.plan(inserted, GuardedEdits.Action.restoreOriginal))
    }

    @Test fun restoreIsUnavailableWhenNothingDiffersOrItWouldOverflowTheField() {
        val same = receipt(raw = "friend")
        assertFalse(GuardedEdits.canRestore(same))
        assertNull(GuardedEdits.plan(same, GuardedEdits.Action.restoreOriginal))
        assertNotNull(GuardedEdits.plan(same, GuardedEdits.Action.undo))
        assertFalse(GuardedEdits.canRestore(receipt(raw = "")))
        val limited = GuardedEdits.receipt(before.copy(maxTextLength = 12), "friend", "a much longer original", after.copy(maxTextLength = 12), 0)!!
        assertNull(GuardedEdits.plan(limited, GuardedEdits.Action.restoreOriginal))
    }
}
