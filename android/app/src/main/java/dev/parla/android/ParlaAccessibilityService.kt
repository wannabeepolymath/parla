package dev.parla.android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.InputMethod
import android.content.Intent
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.util.Log
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
    private fun hasConsent(): Boolean = Store.get(this).accessibilityConsentGranted

    override fun onServiceConnected() {
        // A decline can happen before binding finishes, including when saving it fails.
        if (Store.get(this).accessibilityConsentDeclined) {
            detach()
            disableSelf()
            return
        }
        instance = this
        mutableConnected.value = true
        updateKeyboardBounds()
    }

    override fun onCreateInputMethod(): InputMethod = object : InputMethod(this) {
        override fun onStartInput(attribute: EditorInfo, restarting: Boolean) {
            if (!hasConsent()) { invalidateAnchor(); return }
            super.onStartInput(attribute, restarting)
            inputGeneration++
            invalidateAnchor()
        }

        override fun onFinishInput() {
            if (!hasConsent()) { invalidateAnchor(); return }
            super.onFinishInput()
            inputGeneration++
            invalidateAnchor()
        }

        override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int, candidatesStart: Int, candidatesEnd: Int) {
            if (!hasConsent()) { invalidateAnchor(); return }
            super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
            val anchor = activeAnchor ?: return
            if (newSelStart != anchor.snapshot.selectionStart || newSelEnd != anchor.snapshot.selectionEnd ||
                candidatesStart >= 0 || candidatesEnd >= 0) invalidateAnchor()
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (!hasConsent()) { invalidateAnchor(); mutableKeyboardBounds.value = null; return }
        if (event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED || event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            updateKeyboardBounds()
        }
        val anchor = activeAnchor ?: return
        if (!anchor.valid) return
        when (event.eventType) {
            AccessibilityEvent.TYPE_VIEW_FOCUSED -> {
                val source = event.getSource(0)
                if (source == null || source != anchor.node) invalidateAnchor()
            }
            AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED -> {
                // Our non-focusable overlay and keyboard windows may change without changing the editor.
                if (refreshEditor(anchor) == null) invalidateAnchor()
            }
            AccessibilityEvent.TYPE_WINDOWS_CHANGED -> {
                if (event.windowId == anchor.snapshot.windowId &&
                    event.windowChanges and AccessibilityEvent.WINDOWS_CHANGE_REMOVED != 0) invalidateAnchor()
            }
            AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED, AccessibilityEvent.TYPE_VIEW_TEXT_SELECTION_CHANGED -> {
                val source = event.getSource(0) ?: return
                if (source == anchor.node) {
                    val current = refreshEditor(anchor)
                    if (current == null || !InsertionPolicy.allows(anchor.snapshot, current, true, true)) invalidateAnchor()
                }
            }
        }
    }

    fun captureAnchor(contextEnabled: Boolean, onInvalidated: () -> Unit): EditorAnchor? {
        val log = CaptureLog("captureAnchor")
        log.consent = hasConsent()
        if (log.consent != true) { log.reject("consent"); invalidateAnchor(); return null }
        activeAnchor?.let(::release)
        return runCatching {
            val node = captureFocusedEditor() ?: run {
                log.reject("noFocusedEditor")
                return null
            }
            if (!node.refresh()) {
                log.reject("refreshFailed")
                return null
            }
            val editor = snapshot(node, log) ?: return null
            if (!InsertionPolicy.safe(editor)) {
                log.reject("unsafe")
                return null
            }
            val info = inputMethod?.currentInputEditorInfo
            // When privacy metadata cannot be tied to this editor, suppress history and outgoing context.
            val privateEditor = info == null || info.packageName != editor.packageName || info.inputType != editor.inputType ||
                info.imeOptions and EditorInfo.IME_FLAG_NO_PERSONALIZED_LEARNING != 0
            EditorAnchor(node, editor, session, inputGeneration, InsertionPolicy.context(editor, contextEnabled && !privateEditor),
                privateEditor, InsertionLease(onInvalidated))
                .also { activeAnchor = it; log.accept("privateEditor=$privateEditor") }
        }.onFailure { log.failure(it) }.getOrNull()
    }

    suspend fun insert(anchor: EditorAnchor?, text: String, authorizeWrite: () -> Boolean = { true }): String = withContext(Dispatchers.Main.immediate) {
        insertionMutex.withLock {
            val log = CaptureLog("insert")
            if (text.isBlank()) {
                log.reject("emptyText")
                return@withLock "No text to insert. Try dictating again."
            }
            try {
                log.consent = hasConsent()
                if (log.consent != true) {
                    log.reject("consent")
                    return@withLock recovery(text, "Allow text insertion in parla setup first.")
                }
                if (anchor == null || !anchor.valid || anchor.serviceSession != session || inputGeneration != anchor.inputGeneration) {
                    log.reject("anchor", "present=${anchor != null} valid=${anchor?.valid} " +
                        "sessionSame=${anchor?.serviceSession == session} generationSame=${anchor?.inputGeneration == inputGeneration}")
                    return@withLock recovery(text, "The text field changed or is no longer available.")
                }
                // Refresh only the captured node; never fetch another field to validate it.
                val current = anchor.node
                val editor = refreshEditor(anchor, log)
                    ?: return@withLock recovery(text, "The text field changed or is no longer available.")
                if (!InsertionPolicy.allows(anchor.snapshot, editor, true, anchor.valid)) {
                    log.reject("editorChanged", "safe=${InsertionPolicy.safe(editor)} valid=${anchor.valid} " +
                        "textSame=${anchor.snapshot.text == editor.text} selectionSame=${anchor.snapshot.selectionStart == editor.selectionStart && anchor.snapshot.selectionEnd == editor.selectionEnd}")
                    return@withLock recovery(text, "The text field changed or is no longer available.")
                }
                val expected = InsertionPolicy.replacement(editor, text) ?: run {
                    log.reject("replacement", "dictatedLength=${text.length} maxTextLength=${editor.maxTextLength}")
                    return@withLock recovery(text, "This field cannot accept dictation safely.")
                }
                // A second use of an anchor is never permitted, including after a failed verification.
                if (!anchor.lease.consume()) {
                    log.reject("leaseConsumed")
                    return@withLock recovery(text, "The text field changed.")
                }
                val ime = inputMethod
                val connection = ime?.currentInputConnection
                val imeEditor = ime?.currentInputEditorInfo
                val canCommit = connection != null && ime.currentInputStarted &&
                    imeEditor?.packageName == editor.packageName &&
                    imeEditor.inputType == editor.inputType && inputGeneration == anchor.inputGeneration
                val authorized = authorizeWrite()
                log.consent = hasConsent()
                if (!authorized || log.consent != true) {
                    log.reject("writeCanceled", "authorized=$authorized")
                    return@withLock recovery(text, "Canceled before inserting text.")
                }
                if (canCommit) {
                    // This API has no success return. Once invoked, never perform a second write.
                    connection.commitText(text, 1, null)
                } else {
                    val args = Bundle().apply {
                        putCharSequence(AccessibilityNodeInfo.ACTION_ARGUMENT_SET_TEXT_CHARSEQUENCE, expected)
                    }
                    if (!current.performAction(AccessibilityNodeInfo.ACTION_SET_TEXT, args)) {
                        log.reject("setText", "accepted=false")
                        return@withLock recovery(text, "The app did not accept the text.")
                    }
                }
                if (verify(anchor, expected)) {
                    if (!canCommit && hasConsent()) {
                        val cursor = minOf(editor.selectionStart, editor.selectionEnd) + text.length
                        val selected = current.performAction(AccessibilityNodeInfo.ACTION_SET_SELECTION, Bundle().apply {
                            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_START_INT, cursor)
                            putInt(AccessibilityNodeInfo.ACTION_ARGUMENT_SELECTION_END_INT, cursor)
                        })
                        if (!selected) log.reject("setSelection", "accepted=false cursor=$cursor")
                    }
                    DictationFlow.INSERTED
                } else recovery(text, "Text insertion is unconfirmed. Check the field before pasting.")
            } catch (cancelled: CancellationException) {
                log.failure(cancelled)
                throw cancelled
            } catch (error: Exception) {
                log.failure(error)
                recovery(text, "The text field disconnected. Check it before pasting.")
            } finally {
                if (anchor != null) release(anchor)
            }
        }
    }

    private suspend fun verify(anchor: EditorAnchor, expected: String): Boolean {
        val log = CaptureLog("verify")
        repeat(5) {
            delay(50)
            val editor = refreshEditor(anchor, log) ?: return false
            if (!InsertionPolicy.safe(editor)) { log.reject("unsafe"); return false }
            if (editor.text == expected) return true
        }
        log.reject("textMismatch", "expectedLength=${expected.length} attempts=5")
        return false
    }

    private fun captureFocusedEditor(): AccessibilityNodeInfo? {
        // API 33+: zero requests no prefetching, including no descendant prefetching.
        val focused = findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
        if (focused != null) return focused
        val root = getRootInActiveWindow(0)
        return root?.findFocus(AccessibilityNodeInfo.FOCUS_INPUT)
    }

    private fun refreshEditor(anchor: EditorAnchor, log: CaptureLog = CaptureLog("event")): EditorSnapshot? = runCatching {
        log.editor = null
        log.focusedWindowId = null
        log.textRead = false
        log.consent = hasConsent()
        if (log.consent != true || anchor.serviceSession != session || inputGeneration != anchor.inputGeneration) {
            log.reject("anchor", "sessionSame=${anchor.serviceSession == session} generationSame=${inputGeneration == anchor.inputGeneration}")
            return null
        }
        if (!anchor.node.refresh()) { log.reject("refreshFailed"); return null }
        snapshot(anchor.node, log, anchor.snapshot)
    }.onFailure { log.failure(it) }.getOrNull()

    private fun snapshot(node: AccessibilityNodeInfo, log: CaptureLog, original: EditorSnapshot? = null): EditorSnapshot? {
        log.consent = hasConsent()
        if (log.consent != true) { log.reject("consent"); return null }
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
        log.editor = metadata
        log.textRead = false
        if (InsertionPolicy.sensitive(metadata) || !metadata.editable || !metadata.enabled || !metadata.focused || !metadata.visible) {
            log.reject("metadata")
            return null
        }
        if (original != null && !InsertionPolicy.sameIdentity(original, metadata)) {
            log.reject("identity", "packageSame=${original.packageName == metadata.packageName} " +
                "windowSame=${original.windowId == metadata.windowId} viewSame=${original.viewId == metadata.viewId} " +
                "uniqueSame=${original.uniqueId == metadata.uniqueId} classSame=${original.className == metadata.className} " +
                "inputTypeSame=${original.inputType == metadata.inputType}")
            return null
        }
        // View focus can remain true behind a focused popup. Inspect window metadata only.
        log.focusedWindowId = windows.firstOrNull { it.isFocused }?.id
        if (log.focusedWindowId != metadata.windowId) {
            log.reject("windowMismatch")
            return null
        }
        log.consent = hasConsent()
        if (log.consent != true) { log.reject("consent"); return null }
        val text = if (node.isShowingHintText) "" else node.text?.toString().orEmpty()
        log.rawSelectionStart = node.textSelectionStart
        log.rawSelectionEnd = node.textSelectionEnd
        return metadata.withTextAndSelection(text, log.rawSelectionStart, log.rawSelectionEnd)
            .also { log.editor = it; log.textRead = true }
    }

    /** Metadata only: no field values, hints, descriptions, identities or exception messages. */
    private class CaptureLog(private val stage: String) {
        var consent: Boolean? = null
        var editor: EditorSnapshot? = null
        var focusedWindowId: Int? = null
        var textRead = false
        var rawSelectionStart = -1
        var rawSelectionEnd = -1

        private fun details(): String = buildString {
            append("consent=$consent")
            editor?.let {
                append(" password=${it.password} dataSensitive=${it.dataSensitive} sensitive=${InsertionPolicy.sensitive(it)}")
                append(" editable=${it.editable} enabled=${it.enabled} focused=${it.focused} visible=${it.visible}")
                append(" inputType=${it.inputType} packageBlank=${it.packageName.isBlank()} windowId=${it.windowId} focusedWindowId=$focusedWindowId")
                if (textRead) {
                    append(" textLength=${it.text.length} limit=${InsertionPolicy.MAX_EDITOR_CHARS}")
                    append(" rawSelectionStart=$rawSelectionStart rawSelectionEnd=$rawSelectionEnd")
                    append(" selectionStart=${it.selectionStart} selectionEnd=${it.selectionEnd}")
                } else append(" textLength=unread selection=unread")
            }
        }

        fun reject(reason: String, extra: String = "") {
            Log.i("ParlaCapture", "$stage reject=$reason ${details()} $extra".trimEnd())
        }

        fun accept(extra: String) {
            Log.d("ParlaCapture", "$stage accepted=true ${details()} $extra")
        }

        fun failure(error: Throwable) {
            // Exception messages can embed editor content; retain only their length.
            Log.i("ParlaCapture", "$stage exception=${error.javaClass.name} messageLength=${error.message?.length ?: 0} " +
                "frames=${error.stackTrace.take(5).joinToString { "${it.className}.${it.methodName}:${it.lineNumber}" }}")
        }
    }

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
        if (!hasConsent()) { mutableKeyboardBounds.value = null; return }
        // Window rectangles only. Do not traverse keyboard nodes or read their text.
        mutableKeyboardBounds.value = runCatching {
            windows.firstOrNull { it.type == AccessibilityWindowInfo.TYPE_INPUT_METHOD }?.let { window ->
                val rect = Rect()
                window.getBoundsInScreen(rect)
                ScreenRect(rect.left, rect.top, rect.right, rect.bottom).takeIf { it.width > 0 && it.height > 0 }
            }
        }.onFailure { CaptureLog("keyboardBounds").failure(it) }.getOrNull()
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
