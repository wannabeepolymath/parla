package dev.parla.android

import org.junit.Assert.*
import org.junit.Test

class InsertionPolicyTest {
    private val editor = EditorSnapshot("dev.test", 4, "editor", "1", "EditText", "Hello world", 6, 11,
        editable = true, enabled = true, focused = true, visible = true, inputType = 1, password = false)

    @Test fun originalNodeAndUnchangedSelectionAreRequired() {
        assertTrue(InsertionPolicy.allows(editor, editor.copy(), true, true))
        assertFalse(InsertionPolicy.allows(editor, editor, false, true))
        assertFalse(InsertionPolicy.allows(editor, editor, true, false))
        listOf(editor.copy(packageName = "another"), editor.copy(windowId = 5), editor.copy(viewId = "new"),
            editor.copy(uniqueId = "new"), editor.copy(className = "WebView"), editor.copy(inputType = 0),
            editor.copy(text = "Changed"), editor.copy(selectionStart = 0), editor.copy(selectionEnd = 10))
            .forEach { assertFalse(InsertionPolicy.allows(editor, it, true, true)) }
    }

    @Test fun disabledHiddenUnfocusedAndSensitiveEditorsAreRejected() {
        listOf(editor.copy(editable = false), editor.copy(enabled = false), editor.copy(focused = false),
            editor.copy(visible = false), editor.copy(password = true), editor.copy(dataSensitive = true),
            editor.copy(inputType = 0), editor.copy(inputType = 4), editor.copy(inputType = 2), editor.copy(inputType = 3), editor.copy(inputType = 0x81),
            editor.copy(inputType = 0x91), editor.copy(inputType = 0xe1), editor.copy(inputType = 0x12))
            .forEach { assertFalse(InsertionPolicy.safe(it)); assertEquals("", NearbyText.prefix(it.copy(selectionStart = 11))) }
    }

    @Test fun privacyMetadataIsRecheckedAgainstTheEditorBeforeEachRead() {
        val noLearning = android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING
        assertFalse(InsertionPolicy.privateEditor(editor, "dev.test", 1, 0))
        // The same editor restarting as private (incognito) stops the correction watch.
        assertTrue(InsertionPolicy.privateEditor(editor, "dev.test", 1, noLearning))
        assertTrue(InsertionPolicy.privateEditor(editor, "dev.test", 1, noLearning or android.view.inputmethod.EditorInfo.IME_ACTION_DONE))
        // Metadata that can't be tied to this editor counts as private.
        assertTrue(InsertionPolicy.privateEditor(editor, null, null, 0))
        assertTrue(InsertionPolicy.privateEditor(editor, "other.app", 1, 0))
        assertTrue(InsertionPolicy.privateEditor(editor, "dev.test", 0x81, 0))
    }

    @Test fun identitySurvivesOurWriteButRejectsChangedEditorMetadata() {
        val inserted = editor.copy(text = "Hello friend", selectionStart = 12, selectionEnd = 12)
        assertTrue(InsertionPolicy.sameIdentity(editor, inserted))
        assertFalse(InsertionPolicy.allows(editor, inserted, true, true))
        listOf(editor.copy(packageName = "another"), editor.copy(windowId = 5), editor.copy(viewId = "new"),
            editor.copy(uniqueId = "new"), editor.copy(className = "WebView"), editor.copy(inputType = 0))
            .forEach { assertFalse(InsertionPolicy.sameIdentity(editor, it)) }
    }

    @Test fun replacingSelectedTextPreservesSurroundingTextAndSupportsReversedSelection() {
        assertEquals("Hello friend", InsertionPolicy.replacement(editor, "friend"))
        assertEquals("Hello friend", InsertionPolicy.replacement(editor.copy(selectionStart = 11, selectionEnd = 6), "friend"))
        assertEquals("Hello world!", InsertionPolicy.replacement(editor.copy(selectionStart = 11), "!"))
        assertEquals("Start Hello world", InsertionPolicy.replacement(editor.copy(selectionStart = 0, selectionEnd = 0), "Start "))
    }

    @Test fun emptyUnknownSelectionAllowsInsertionAndVerification() {
        val empty = editor.withTextAndSelection("", -1, -1)
        assertEquals(0, empty.selectionStart)
        assertEquals(0, empty.selectionEnd)
        assertTrue(InsertionPolicy.allows(empty, editor.withTextAndSelection("", -1, -1), true, true))
        val dictated = "First words"
        val expected = InsertionPolicy.replacement(empty, dictated)
        assertEquals(dictated, expected)
        val cursor = minOf(empty.selectionStart, empty.selectionEnd) + dictated.length
        val inserted = empty.withTextAndSelection(dictated, cursor, cursor)
        assertEquals(dictated.length, inserted.selectionStart)
        assertEquals(dictated.length, inserted.selectionEnd)
        assertTrue(InsertionPolicy.safe(inserted))
        assertTrue(InsertionPolicy.sameIdentity(empty, inserted))
        assertEquals(expected, inserted.text)
    }

    @Test fun eitherUnknownEndpointInAnEmptyEditorNormalizesBothEndpoints() {
        for ((start, end) in listOf(-1 to 0, 0 to -1)) {
            val empty = editor.withTextAndSelection("", start, end)
            assertEquals(0, empty.selectionStart)
            assertEquals(0, empty.selectionEnd)
            assertTrue(InsertionPolicy.safe(empty))
        }
    }

    @Test fun nonEmptyUnknownSelectionsStayRejected() {
        for ((start, end) in listOf(-1 to -1, -1 to 0, 0 to -1)) {
            val unknown = editor.withTextAndSelection(editor.text, start, end)
            assertEquals(start, unknown.selectionStart)
            assertEquals(end, unknown.selectionEnd)
            assertFalse(InsertionPolicy.allows(unknown, unknown, true, true))
            assertNull(InsertionPolicy.replacement(unknown, "dictated"))
        }
    }

    @Test fun knownSelectionsAreNotClampedBySnapshotConstruction() {
        assertEquals(editor, editor.withTextAndSelection(editor.text, 6, 11))
        val empty = editor.withTextAndSelection("", 0, 0)
        assertTrue(InsertionPolicy.safe(empty))
        val invalid = editor.withTextAndSelection("", 1, 1)
        assertEquals(1, invalid.selectionStart)
        assertFalse(InsertionPolicy.safe(invalid))
    }

    @Test fun invalidSelectionsAndEmptyResultsNeverProduceAWrite() {
        assertNull(InsertionPolicy.replacement(editor.copy(selectionStart = -1), "a"))
        assertNull(InsertionPolicy.replacement(editor.copy(selectionEnd = 12), "a"))
        assertNull(InsertionPolicy.replacement(editor, " "))
        assertNull(InsertionPolicy.replacement(editor.copy(maxTextLength = 10), "friends"))
        assertNull(InsertionPolicy.replacement(editor, "a".repeat(100_001)))
        assertFalse(InsertionPolicy.safe(editor.copy(text = "a".repeat(100_001))))
    }
}
