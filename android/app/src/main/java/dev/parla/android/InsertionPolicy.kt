package dev.parla.android

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

    fun sameIdentity(original: EditorSnapshot, current: EditorSnapshot): Boolean =
        original.packageName == current.packageName && original.windowId == current.windowId &&
            original.viewId == current.viewId && original.uniqueId == current.uniqueId &&
            original.className == current.className && original.inputType == current.inputType

    fun allows(original: EditorSnapshot, current: EditorSnapshot, sameNode: Boolean, valid: Boolean): Boolean =
        valid && sameNode && safe(original) && safe(current) && sameIdentity(original, current) &&
            original.text == current.text && original.selectionStart == current.selectionStart &&
            original.selectionEnd == current.selectionEnd

    fun replacement(editor: EditorSnapshot, dictated: String): String? {
        if (!safe(editor) || dictated.isBlank() || dictated.length > MAX_EDITOR_CHARS) return null
        val start = minOf(editor.selectionStart, editor.selectionEnd)
        val end = maxOf(editor.selectionStart, editor.selectionEnd)
        val length = editor.text.length - (end - start) + dictated.length
        if (length > MAX_EDITOR_CHARS || (editor.maxTextLength > 0 && length > editor.maxTextLength)) return null
        return editor.text.substring(0, start) + dictated + editor.text.substring(end)
    }
}
