package dev.parla.android

/**
 * Mac GuardedDictationEdits: RAM-only evidence of one verified insertion. Never logged, persisted or
 * shown. Indices are UTF-16, like [EditorSnapshot].
 */
internal class EditReceipt(val before: EditorSnapshot, val after: EditorSnapshot, val start: Int, val inserted: String, val raw: String, val expiresAt: Long)

internal object GuardedEdits {
    const val LIFETIME_MS = 10 * 60 * 1000L
    const val REFUSED = "The text changed since parla inserted it, so nothing was changed."
    const val UNVERIFIED = "Couldn’t confirm the change. Check the text field."
    enum class Action { undo, restoreOriginal }
    data class Plan(val text: String, val caret: Int)

    /** Authority only from an exact readback: the same editor, our replacement, a collapsed caret right after it. */
    fun receipt(before: EditorSnapshot, inserted: String, raw: String, after: EditorSnapshot, now: Long): EditReceipt? {
        val start = minOf(before.selectionStart, before.selectionEnd)
        val caret = start + inserted.length
        if (inserted.isEmpty() || !InsertionPolicy.safe(before) || !InsertionPolicy.safe(after) || !InsertionPolicy.sameIdentity(before, after) ||
            after.text != InsertionPolicy.replacement(before, inserted) || after.selectionStart != caret || after.selectionEnd != caret) return null
        return EditReceipt(before, after, start, inserted, raw, now + LIFETIME_MS)
    }

    /** The last check before the single write: exact identity, full text and caret, unexpired. */
    fun matches(receipt: EditReceipt, current: EditorSnapshot, now: Long): Boolean = now < receipt.expiresAt &&
        InsertionPolicy.safe(current) && InsertionPolicy.sameIdentity(receipt.after, current) && current.text == receipt.after.text &&
        current.selectionStart == receipt.after.selectionStart && current.selectionEnd == receipt.after.selectionEnd

    fun canRestore(receipt: EditReceipt) = receipt.raw.isNotEmpty() && receipt.raw != receipt.inserted

    /** Undo restores the field before dictation with the caret where it started; restore swaps in the original words. */
    fun plan(receipt: EditReceipt, action: Action): Plan? {
        val plan = when (action) {
            Action.undo -> Plan(receipt.before.text, receipt.start)
            Action.restoreOriginal -> {
                if (!canRestore(receipt)) return null
                val after = receipt.after.text
                Plan(after.substring(0, receipt.start) + receipt.raw + after.substring(receipt.start + receipt.inserted.length), receipt.start + receipt.raw.length)
            }
        }
        val limit = receipt.after.maxTextLength
        return plan.takeIf { it.text.length <= InsertionPolicy.MAX_EDITOR_CHARS && (limit <= 0 || it.text.length <= limit) }
    }
}
