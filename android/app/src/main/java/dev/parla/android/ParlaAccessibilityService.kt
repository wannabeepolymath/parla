package dev.parla.android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.InputMethod
import android.content.Intent
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.view.accessibility.AccessibilityEvent
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import android.view.inputmethod.EditorInfo
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.util.UUID

class EditorAnchor internal constructor(
    internal val node: AccessibilityNodeInfo,
    internal val snapshot: EditorSnapshot,
    internal val serviceSession: String,
    internal val inputGeneration: Long,
    val context: String,
    val privateEditor: Boolean,
    internal val lease: InsertionLease,
) {
    internal val valid: Boolean get() = lease.valid
}

/** Only the node captured at recording start may be mutated. Never search for a replacement. */
class ParlaAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile var instance: ParlaAccessibilityService? = null
            private set
        private val mutableConnected = MutableStateFlow(false)
        val connected = mutableConnected.asStateFlow()
        private val mutableKeyboardBounds = MutableStateFlow<ScreenRect?>(null)
        internal val keyboardBounds = mutableKeyboardBounds.asStateFlow()
    }

    private val session = UUID.randomUUID().toString()
    private val insertionMutex = Mutex()
    private var inputGeneration = 0L
    private var activeAnchor: EditorAnchor? = null

    override fun onServiceConnected() {
        instance = this
        mutableConnected.value = true
        updateKeyboardBounds()
    }

    override fun onCreateInputMethod(): InputMethod = object : InputMethod(this) {
        override fun onStartInput(attribute: EditorInfo, restarting: Boolean) {
            super.onStartInput(attribute, restarting)
            inputGeneration++
            invalidateAnchor()
        }

        override fun onFinishInput() {
            super.onFinishInput()
            inputGeneration++
            invalidateAnchor()
        }

        override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int, candidatesStart: Int, candidatesEnd: Int) {
            super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
            val anchor = activeAnchor ?: return
            if (newSelStart != anchor.snapshot.selectionStart || newSelEnd != anchor.snapshot.selectionEnd ||
                candidatesStart >= 0 || candidatesEnd >= 0) invalidateAnchor()
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED || event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            updateKeyboardBounds()
        }
        val anchor = activeAnchor ?: return
        if (!anchor.valid) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_FOCUSED -> {
                val source = event.source
                if (source == null || source != anchor.node) invalidateAnchor()
            }
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                // Our non-focusable overlay and keyboard windows may change without changing the editor.
                val current = focusedEditor()
                if (current == null || current != anchor.node) invalidateAnchor()
            }
            AccessibilityEvent.TYPE_WINDOWS_CHANGED -> {
                if (event.windowId == anchor.snapshot.windowId &&
                    event.windowChanges and AccessibilityEvent.WINDOWS_CHANGE_REMOVED != 0) invalidateAnchor()
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED, AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED -> {
                val source = event.source ?: return
                if (source == anchor.node) {
                    val current = snapshot(source)
                    if (current == null || !InsertionPolicy.allows(anchor.snapshot, current, true, true)) invalidateAnchor()
                }
            }
        }
    }

    fun captureAnchor(contextEnabled: Boolean, onInvalidated: () -> Unit): EditorAnchor? {
        activeAnchor?.let(::release)
        return runCatching {
            val node = focusedEditor() ?: return null
            if (!node.refresh()) return null
            val editor = snapshot(node) ?: return null
            if (!InsertionPolicy.safe(editor)) return null
            val info = inputMethod?.currentInputEditorInfo
            // When privacy metadata cannot be tied to this editor, suppress history and outgoing context.
            val privateEditor = info == null || info.packageName != editor.packageName || info.inputType != editor.inputType ||
                info.imeOptions and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0
            EditorAnchor(node, editor, session, inputGeneration, InsertionPolicy.context(editor, contextEnabled && !privateEditor),
                privateEditor, InsertionLease(onInvalidated))
                .also { activeAnchor = it }
        }.getOrNull()
    }

    suspend fun insert(anchor: EditorAnchor?, text: String, authorizeWrite: () -> Boolean = { true }): String = withContext(Dispatchers.Main.immediate) {
        insertionMutex.withLock {
            if (text.isBlank()) return@withLock "No text to insert. Try dictating again."
            try {
                val current = focusedEditor()
                val editor = current?.takeIf { it.refresh() }?.let(::snapshot)
                if (anchor == null || current == null || editor == null || anchor.serviceSession != session || inputGeneration != anchor.inputGeneration ||
                    !InsertionPolicy.allows(anchor.snapshot, editor, current == anchor.node, anchor.valid)) {
                    return@withLock recovery(text, "The original editor changed or isn't available.")
                }
                val expected = InsertionPolicy.replacement(editor, text)
                    ?: return@withLock recovery(text, "This editor can't accept the dictation safely.")
                // A second use of an anchor is never permitted, including after a failed verification.
                if (!anchor.lease.consume()) return@withLock recovery(text, "The original editor changed.")
                val ime = inputMethod
                val connection = ime?.currentInputConnection
                val imeEditor = ime?.currentInputEditorInfo
                val canCommit = connection != null && ime.currentInputStarted &&
                    imeEditor?.packageName == editor.packageName &&
                    imeEditor.inputType == editor.inputType && inputGeneration == anchor.inputGeneration
                if (!authorizeWrite()) return@withLock recovery(text, "Delivery canceled before writing.")
                if (canCommit) {
                    // This API has no success return. Once invoked, never perform a second write.
                    connection.commitText(text, 1, null)
                } else {
                    val args = Bundle().apply {
                        putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, expected)
                    }
                    if (!current.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                        return@withLock recovery(text, "The editor declined text insertion.")
                    }
                }
                if (verify(anchor, expected)) {
                    if (!canCommit) {
                        val cursor = minOf(editor.selectionStart, editor.selectionEnd) + text.length
                        current.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, cursor)
                            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, cursor)
                        })
                    }
                    "Inserted into your original editor."
                } else recovery(text, "Insertion couldn't be confirmed; check the editor before pasting.")
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (_: Exception) {
                recovery(text, "The editor connection became unavailable; check before pasting.")
            } finally {
                if (anchor != null) release(anchor)
            }
        }
    }

    private suspend fun verify(anchor: EditorAnchor, expected: String): Boolean {
        repeat(5) {
            delay(50)
            val current = focusedEditor() ?: return false
            if (current != anchor.node || !current.refresh()) return false
            val editor = snapshot(current) ?: return false
            if (!InsertionPolicy.safe(editor) || editor.packageName != anchor.snapshot.packageName ||
                editor.windowId != anchor.snapshot.windowId || editor.inputType != anchor.snapshot.inputType) return false
            if (editor.text == expected) return true
        }
        return false
    }

    private fun focusedEditor(): AccessibilityNodeInfo? =
        findFocus(AccessibilityNodeInfo.FOCUS_INPUT) ?: rootInActiveWindow?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)

    private fun snapshot(node: AccessibilityNodeInfo): EditorSnapshot? = runCatching {
        // Password/sensitive metadata is checked before reading the node's text.
        val metadata = EditorSnapshot(
            packageName = node.packageName?.toString().orEmpty(),
            windowId = node.windowId,
            viewId = node.viewIdResourceName,
            uniqueId = node.uniqueId,
            className = node.className?.toString().orEmpty(),
            text = "", selectionStart = 0, selectionEnd = 0,
            editable = node.isEditable, enabled = node.isEnabled, focused = node.isFocused,
            visible = node.isVisibleToUser, inputType = node.inputType, password = node.isPassword,
            dataSensitive = Build.VERSION.SDK_INT >= 34 && node.isAccessibilityDataSensitive,
            maxTextLength = node.maxTextLength,
        )
        if (InsertionPolicy.sensitive(metadata) || !metadata.editable || !metadata.enabled) return null
        metadata.copy(text = if (node.isShowingHintText) "" else node.text?.toString().orEmpty(),
            selectionStart = node.textSelectionStart, selectionEnd = node.textSelectionEnd)
    }.getOrNull()

    private fun recovery(text: String, reason: String): String {
        return if (text.isBlank()) reason else "$reason Open parla to copy your result."
    }

    fun release(anchor: EditorAnchor) {
        anchor.lease.release()
        if (activeAnchor === anchor) activeAnchor = null
    }

    private fun invalidateAnchor() {
        val anchor = activeAnchor ?: return
        activeAnchor = null
        anchor.lease.invalidate()
    }

    private fun updateKeyboardBounds() {
        // Window rectangles only. Do not traverse keyboard nodes or read their text.
        mutableKeyboardBounds.value = runCatching {
            windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }?.let { window ->
                val rect = Rect()
                window.getBoundsInScreen(rect)
                ScreenRect(rect.left, rect.top, rect.right, rect.bottom).takeIf { it.width > 0 && it.height > 0 }
            }
        }.getOrNull()
    }

    override fun onInterrupt() {
        invalidateAnchor()
    }

    override fun onUnbind(intent: Intent?): Boolean {
        detach()
        return super.onUnbind(intent)
    }

    override fun onDestroy() {
        detach()
        super.onDestroy()
    }

    private fun detach() {
        invalidateAnchor()
        if (instance === this) {
            instance = null
            mutableConnected.value = false
            mutableKeyboardBounds.value = null
        }
    }
}
