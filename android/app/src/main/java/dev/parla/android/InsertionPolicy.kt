package dev.parla.android

import java.lang.Character.UnicodeScript

/** A captured editor is an insertion capability, never a query for a new target. */
data class EditorSnapshot(
    val packageName: String,
    val windowId: Int,
    val viewId: String?,
    val uniqueId: String?,
    val className: String,
    val text: String,
    val selectionStart: Int,
    val selectionEnd: Int,
    val editable: Boolean,
    val enabled: Boolean,
    val focused: Boolean,
    val visible: Boolean,
    val inputType: Int,
    val password: Boolean,
    val dataSensitive: Boolean = false,
    val maxTextLength: Int = -1,
) {
    internal fun withTextAndSelection(text: String, start: Int, end: Int): EditorSnapshot {
        // An empty editor has only one possible cursor position, even when Android reports -1.
        val emptyUnknownSelection = text.isEmpty() && (start < 0 || end < 0)
        return copy(text = text, selectionStart = if (emptyUnknownSelection) 0 else start,
            selectionEnd = if (emptyUnknownSelection) 0 else end)
    }
}

object InsertionPolicy {
    const val MAX_EDITOR_CHARS = 100_000

    /** Non-text classes and password variations, from input type alone. */
    fun sensitiveType(inputType: Int): Boolean = inputType and 0x0f != 1 || inputType and 0x0ff0 in setOf(0x80, 0x90, 0xe0)
    fun sensitive(editor: EditorSnapshot): Boolean = editor.password || editor.dataSensitive || sensitiveType(editor.inputType)

    fun safe(editor: EditorSnapshot): Boolean = editor.packageName.isNotBlank() &&
        editor.windowId >= 0 && editor.editable && editor.enabled && editor.focused &&
        editor.visible && !sensitive(editor) && editor.text.length <= MAX_EDITOR_CHARS &&
        editor.selectionStart in 0..editor.text.length && editor.selectionEnd in 0..editor.text.length

    /** Private when IME metadata can't be tied to this editor, or the app asks keyboards not to learn from it. */
    fun privateEditor(editor: EditorSnapshot, infoPackage: String?, infoInputType: Int?, imeOptions: Int): Boolean =
        infoPackage == null || infoPackage != editor.packageName || infoInputType != editor.inputType ||
            imeOptions and android.view.inputmethod.EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0

    fun sameIdentity(original: EditorSnapshot, current: EditorSnapshot): Boolean =
        original.packageName == current.packageName && original.windowId == current.windowId &&
            original.viewId == current.viewId && original.uniqueId == current.uniqueId &&
            original.className == current.className && original.inputType == current.inputType

    fun allows(original: EditorSnapshot, current: EditorSnapshot, sameNode: Boolean, valid: Boolean): Boolean =
        valid && sameNode && safe(original) && safe(current) && sameIdentity(original, current) &&
            original.text == current.text && original.selectionStart == current.selectionStart &&
            original.selectionEnd == current.selectionEnd

    /** Our write and nothing else: the same editor, our replacement, a collapsed caret right after it. */
    fun inserted(before: EditorSnapshot, dictated: String, after: EditorSnapshot): Boolean {
        val caret = minOf(before.selectionStart, before.selectionEnd) + dictated.length
        return dictated.isNotEmpty() && safe(before) && safe(after) && sameIdentity(before, after) &&
            after.text == replacement(before, dictated) && after.selectionStart == caret && after.selectionEnd == caret
    }

    /**
     * [dictated] plus a space when the caret sits right before a word, so "alpha |omega" doesn't become
     * "alpha middleomega". Nothing before punctuation, whitespace or the end, nor in scripts written without
     * spaces. The Mac app pastes verbatim (no caret-context spacing or casing), so the left side stays as dictated.
     */
    fun separated(editor: EditorSnapshot, dictated: String): String {
        val end = maxOf(editor.selectionStart, editor.selectionEnd)
        if (dictated.isEmpty() || end !in editor.text.indices) return dictated
        val next = editor.text.codePointAt(end); val last = dictated.codePointBefore(dictated.length)
        val joins = Character.isLetterOrDigit(next) && !Character.isWhitespace(last) && !Character.isSpaceChar(last) &&
            UnicodeScript.of(next) !in unspaced && UnicodeScript.of(last) !in unspaced
        return if (joins) "$dictated " else dictated
    }
    // ponytail: common scripts written without spaces; add one here if it shows up.
    private val unspaced = setOf(UnicodeScript.HAN, UnicodeScript.HIRAGANA, UnicodeScript.KATAKANA, UnicodeScript.THAI,
        UnicodeScript.LAO, UnicodeScript.KHMER, UnicodeScript.MYANMAR)

    fun replacement(editor: EditorSnapshot, dictated: String): String? {
        if (!safe(editor) || dictated.isBlank() || dictated.length > MAX_EDITOR_CHARS) return null
        val start = minOf(editor.selectionStart, editor.selectionEnd)
        val end = maxOf(editor.selectionStart, editor.selectionEnd)
        val length = editor.text.length - (end - start) + dictated.length
        if (length > MAX_EDITOR_CHARS || (editor.maxTextLength > 0 && length > editor.maxTextLength)) return null
        return editor.text.substring(0, start) + dictated + editor.text.substring(end)
    }
}
