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
            .forEach { assertFalse(InsertionPolicy.safe(it)); assertEquals("", InsertionPolicy.context(it, true)) }
    }

    @Test fun replacingSelectedTextPreservesSurroundingTextAndSupportsReversedSelection() {
        assertEquals("Hello friend", InsertionPolicy.replacement(editor, "friend"))
        assertEquals("Hello friend", InsertionPolicy.replacement(editor.copy(selectionStart = 11, selectionEnd = 6), "friend"))
        assertEquals("Hello world!", InsertionPolicy.replacement(editor.copy(selectionStart = 11), "!"))
        assertEquals("Start Hello world", InsertionPolicy.replacement(editor.copy(selectionStart = 0, selectionEnd = 0), "Start "))
    }

    @Test fun invalidSelectionsAndEmptyResultsNeverProduceAWrite() {
        assertNull(InsertionPolicy.replacement(editor.copy(selectionStart = -1), "a"))
        assertNull(InsertionPolicy.replacement(editor.copy(selectionEnd = 12), "a"))
        assertNull(InsertionPolicy.replacement(editor, " "))
        assertNull(InsertionPolicy.replacement(editor.copy(maxTextLength = 10), "friends"))
        assertNull(InsertionPolicy.replacement(editor, "a".repeat(100_001)))
        assertFalse(InsertionPolicy.safe(editor.copy(text = "a".repeat(100_001))))
    }

    @Test fun contextIsOptInBoundedAndExcludedForUrlEmailAndSensitiveFields() {
        assertEquals("", InsertionPolicy.context(editor, false))
        assertEquals(editor.text, InsertionPolicy.context(editor, true))
        for (type in listOf(0x11, 0x21, 0xd1)) assertEquals("", InsertionPolicy.context(editor.copy(inputType = type), true))
        val long = editor.copy(text = "a".repeat(10_000), selectionStart = 5_000, selectionEnd = 5_000)
        assertEquals(1_500, InsertionPolicy.context(long, true).length)
        assertEquals(1_500, InsertionPolicy.context(long.copy(selectionStart = 10_000), true).length)
    }
}
