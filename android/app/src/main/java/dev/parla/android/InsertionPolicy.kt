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
)

object InsertionPolicy {
    const val MAX_EDITOR_CHARS = 100_000
    const val MAX_CONTEXT_CHARS = 1_500

    fun sensitive(editor: EditorSnapshot): Boolean {
        val inputClass = editor.inputType and 0x0f
        val variation = editor.inputType and 0x0ff0
        return editor.password || editor.dataSensitive || inputClass != 1 ||
            (inputClass == 1 && variation in setOf(0x80, 0x90, 0xe0))
    }

    fun safe(editor: EditorSnapshot): Boolean = editor.packageName.isNotBlank() &&
        editor.windowId >= 0 && editor.editable && editor.enabled && editor.focused &&
        editor.visible && !sensitive(editor) && editor.text.length <= MAX_EDITOR_CHARS &&
        editor.selectionStart in 0..editor.text.length && editor.selectionEnd in 0..editor.text.length

    fun allows(original: EditorSnapshot, current: EditorSnapshot, sameNode: Boolean, valid: Boolean): Boolean =
        valid && sameNode && safe(original) && safe(current) &&
            original.packageName == current.packageName && original.windowId == current.windowId &&
            original.viewId == current.viewId && original.uniqueId == current.uniqueId &&
            original.className == current.className && original.inputType == current.inputType &&
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

    fun context(editor: EditorSnapshot, enabled: Boolean): String {
        // URL and email fields can be valid dictation targets but are never context sources.
        val variation = editor.inputType and 0x0ff0
        if (!enabled || !safe(editor) || (editor.inputType and 0x0f == 1 && variation in setOf(0x10, 0x20, 0xd0))) return ""
        val cursor = minOf(editor.selectionStart, editor.selectionEnd)
        val start = (cursor - MAX_CONTEXT_CHARS / 2).coerceAtLeast(0)
            .coerceAtMost((editor.text.length - MAX_CONTEXT_CHARS).coerceAtLeast(0))
        return editor.text.substring(start, (start + MAX_CONTEXT_CHARS).coerceAtMost(editor.text.length))
    }
}
