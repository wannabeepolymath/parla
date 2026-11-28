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

    @Test fun correctionWatchNeedsTheExactPostWriteFieldAndCaret() {
        val after = editor.copy(text = "Hello friend", selectionStart = 12, selectionEnd = 12)
        assertTrue(InsertionPolicy.inserted(editor, "friend", after))
        // Any other readback is not our write.
        listOf(after.copy(text = "Hello friend!"), after.copy(selectionStart = 11, selectionEnd = 11), after.copy(selectionStart = 6),
            after.copy(windowId = 5), after.copy(viewId = "other"), after.copy(uniqueId = "2"), after.copy(packageName = "other"),
            after.copy(focused = false), after.copy(password = true))
            .forEach { assertFalse(it.toString(), InsertionPolicy.inserted(editor, "friend", it)) }
        assertFalse(InsertionPolicy.inserted(editor, "", editor))
        assertFalse(InsertionPolicy.inserted(editor.copy(inputType = 0x81), "friend", after.copy(inputType = 0x81)))
    }

    @Test fun aSpaceSeparatesDictationFromAWordRightAfterTheCaret() {
        fun at(text: String, start: Int, end: Int = start, dictated: String = "Middle.") =
            editor.copy(text = text, selectionStart = start, selectionEnd = end).let { e -> InsertionPolicy.replacement(e, InsertionPolicy.separated(e, dictated)) }
        assertEquals("alpha Middle. omega", at("alpha omega", 6))                // device F2: was "alpha Middle.omega"
        assertEquals("Middle.", at("", 0))                                       // empty field
        assertEquals("alpha Middle.", at("alpha ", 6))                           // end of text
        assertEquals("alpha Middle. 42", at("alpha 42", 6))                      // before a digit
        assertEquals("alpha Middle. éclair", at("alpha éclair", 6))              // before a non-ASCII letter
        assertEquals("alpha Middle, omega", at("alpha , omega", 6, dictated = "Middle"))  // before punctuation: no space
        assertEquals("alpha Middle.. omega", at("alpha . omega", 6))
        assertEquals("alpha Middle. omega", at("alpha  omega", 6))               // before whitespace: no double space
        assertEquals("alpha Middle.\nomega", at("alpha \nomega", 6))
        assertEquals("alpha Middle. omega", at("alpha  omega", 6))
        assertEquals("alpha middle omega", at("alpha omega", 6, dictated = "middle "))  // dictation already ends in a space
        assertEquals("on my favorite kitchen", at("on the kitchen", 3, 6, "my favorite"))       // selection: existing space kept
        assertEquals("on my favorite kitchen", at("on the kitchen", 6, 3, "my favorite"))       // reversed selection
        assertEquals("on my favorite kitchen", at("on thekitchen", 3, 6, "my favorite"))        // selection ending before a letter
        // Scripts written without spaces never get one.
        assertEquals("我喜欢你好世界", at("我喜欢世界", 3, dictated = "你好"))
        assertEquals("Hello世界", at("世界", 0, dictated = "Hello"))
        assertEquals("你好world", at("world", 0, dictated = "你好"))
        assertEquals("こんにちはカタカナ", at("カタカナ", 0, dictated = "こんにちは"))
        assertEquals("Hiสวัสดี", at("สวัสดี", 0, dictated = "Hi"))
        // The script comes from the word, not one code point: decomposed kana, ー, a variation selector, 。.
        assertEquals("が" + "world", at("world", 0, dictated = "が"))                    // precomposed が
        assertEquals("が" + "world", at("world", 0, dictated = "が"))        // か + combining voiced mark
        assertEquals("スーパーworld", at("world", 0, dictated = "スーパー"))                      // ー is COMMON
        assertEquals("葛︀world", at("world", 0, dictated = "葛︀"))            // Han + variation selector
        assertEquals("你好。world", at("world", 0, dictated = "你好。"))
        assertEquals("Helloー世界", at("ー世界", 0, dictated = "Hello"))                          // next word starts with ー
        assertEquals("Hello 123", at("123", 0, dictated = "Hello"))                              // digits alone stay spaced
        assertEquals("Hello 123,你好", at("123,你好", 0, dictated = "Hello"))                     // digits and punctuation end the walk
        assertEquals("Total 123.45,数量", at("123.45,数量", 0, dictated = "Total"))
        assertEquals("「東京」world", at("world", 0, dictated = "「東京」"))                       // CJK brackets attach
    }

    @Test fun addressesNeverGetAnAutomaticSpace() {
        fun at(text: String, dictated: String, inputType: Int = 1) =
            editor.copy(text = text, selectionStart = 0, selectionEnd = 0, inputType = inputType).let { e -> InsertionPolicy.replacement(e, InsertionPolicy.separated(e, dictated)) }
        assertEquals("support@example.com", at("example.com", "support@"))                     // plain text field
        assertEquals("https://example.com", at("example.com", "https://"))
        assertEquals("name.surname@x.com", at("surname@x.com", "name.", inputType = 0x21))     // email
        assertEquals("name.surname@x.com", at("surname@x.com", "name.", inputType = 0xd1))     // web email
        assertEquals("www.example.com", at("example.com", "www.", inputType = 0x11))           // URI
        assertEquals("www. example.com", at("example.com", "www."))                            // prose keeps the F2 space
    }
}
