package dev.parla.android

import android.accessibilityservice.AccessibilityService
import android.accessibilityservice.InputMethod
import android.content.Intent
import android.graphics.Rect
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
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

/** What the control may offer right now. Selection comes from IME positions only; no text is read for it. */
data class EditActions(val selection: Boolean = false)

/** Only the node captured at recording start may be mutated. Never search for a replacement. */
class ParlaAccessibilityService : AccessibilityService() {
    companion object {
        @Volatile var instance: ParlaAccessibilityService? = null
            private set
        private val mutableConnected = MutableStateFlow(false)
        val connected = mutableConnected.asStateFlow()
        private val mutableKeyboardBounds = MutableStateFlow<ScreenRect?>(null)
        internal val keyboardBounds = mutableKeyboardBounds.asStateFlow()
        private val mutableEditActions = MutableStateFlow(EditActions())
        val editActions = mutableEditActions.asStateFlow()
        private const val SETTLE_MS = 600L
        private const val WATCH_MS = 60_000L
    }

    /** Mac CorrectionWatcher: one field, one minute, one proposal. Holds no text beyond that field's own. */
    private class CorrectionWatch(val node: AccessibilityNodeInfo, val baseline: EditorSnapshot, val inserted: String, val dictionary: List<String>, val deadline: Long)

    private val session = UUID.randomUUID().toString()
    private val insertionMutex = Mutex()
    private var inputGeneration = 0L
    private var activeAnchor: EditorAnchor? = null
    private var watch: CorrectionWatch? = null
    private var selection = false
    private val handler = Handler(Looper.getMainLooper())
    private val evaluate = Runnable { evaluateCorrection() }
    private val giveUp = Runnable { disarmCorrection() }
    private fun hasConsent(): Boolean = Store.get(this).accessibilityConsentGranted
    private fun publish() {
        mutableEditActions.value = if (!hasConsent()) EditActions() else EditActions(selection)
    }
    private fun revokeEdits() { invalidateAnchor(); disarmCorrection(); selection = false; publish() }

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
            if (!hasConsent()) { revokeEdits(); return }
            super.onStartInput(attribute, restarting)
            inputGeneration++
            // A restarted input can carry new privacy metadata: the correction watch never outlives it.
            invalidateAnchor(); disarmCorrection()
            selection = !InsertionPolicy.sensitiveType(attribute.inputType) && attribute.initialSelStart >= 0 && attribute.initialSelStart != attribute.initialSelEnd
            publish()
        }

        override fun onFinishInput() {
            if (!hasConsent()) { revokeEdits(); return }
            super.onFinishInput()
            inputGeneration++
            invalidateAnchor(); disarmCorrection()
            selection = false; publish()
        }

        override fun onUpdateSelection(oldSelStart: Int, oldSelEnd: Int, newSelStart: Int, newSelEnd: Int, candidatesStart: Int, candidatesEnd: Int) {
            if (!hasConsent()) { revokeEdits(); return }
            super.onUpdateSelection(oldSelStart, oldSelEnd, newSelStart, newSelEnd, candidatesStart, candidatesEnd)
            selection = newSelStart != newSelEnd && currentInputEditorInfo?.inputType?.let { !InsertionPolicy.sensitiveType(it) } == true
            publish()
            val anchor = activeAnchor ?: return
            if (newSelStart != anchor.snapshot.selectionStart || newSelEnd != anchor.snapshot.selectionEnd ||
                candidatesStart >= 0 || candidatesEnd >= 0) invalidateAnchor()
        }
    }

    override fun onAccessibilityEvent(event: AccessibilityEvent) {
        if (!hasConsent()) { revokeEdits(); mutableKeyboardBounds.value = null; return }
        if (event.eventType == AccessibilityEvent.TYPE_WINDOWS_CHANGED || event.eventType == AccessibilityEvent.TYPE_WINDOW_STATE_CHANGED) {
            updateKeyboardBounds()
        }
        observeEdits(event)
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

    /**
     * [nearby] decides, per app, whether a reviewed grant allows the bounded prefix. [requireSelection] freezes a
     * non-empty selection for a selected-text change; any later selection or text change invalidates it.
     */
    fun captureAnchor(nearby: (String) -> Boolean, requireSelection: Boolean = false, onInvalidated: () -> Unit): EditorAnchor? {
        val log = CaptureLog("captureAnchor")
        log.consent = hasConsent()
        if (log.consent != true) { log.reject("consent"); revokeEdits(); return null }
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
            if (requireSelection && editor.selectionStart == editor.selectionEnd) {
                log.reject("noSelection")
                return null
            }
            val info = inputMethod?.currentInputEditorInfo
            // When privacy metadata cannot be tied to this editor, suppress history and outgoing context.
            val privateEditor = InsertionPolicy.privateEditor(editor, info?.packageName, info?.inputType, info?.imeOptions ?: 0)
            val context = if (!requireSelection && !privateEditor && nearby(editor.packageName)) NearbyText.prefix(editor) else ""
            // A new capture ends the previous dictation's correction watch (Mac captureAccepted).
            disarmCorrection()
            EditorAnchor(node, editor, session, inputGeneration, context, privateEditor, InsertionLease(onInvalidated))
                .also { activeAnchor = it; log.accept("privateEditor=$privateEditor nearbyLength=${context.length}") }
        }.onFailure { log.failure(it) }.getOrNull()
    }

    /** [learn]: the dictionary for a short correction watch (never for private editors or nearby-text results). */
    suspend fun insert(anchor: EditorAnchor?, text: String, authorizeWrite: () -> Boolean = { true },
                       learn: List<String>? = null): String = withContext(Dispatchers.Main.immediate) {
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
                    if (learn != null && !anchor.privateEditor) watchCorrection(anchor, text, learn)
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

    /** Reads only, bounded: the watch needs the exact post-write field, including the caret right after our text. */
    private suspend fun watchCorrection(anchor: EditorAnchor, text: String, learn: List<String>) {
        repeat(5) { attempt ->
            if (attempt > 0) delay(50)
            val after = refreshNode(anchor.node, anchor.snapshot) ?: return@repeat
            if (!InsertionPolicy.inserted(anchor.snapshot, text, after)) return@repeat
            watch = CorrectionWatch(anchor.node, after, text, learn, SystemClock.elapsedRealtime() + WATCH_MS)
            handler.postDelayed(giveUp, WATCH_MS)
            return
        }
        CaptureLog("watch").reject("unconfirmed")
    }

    private fun observeEdits(event: AccessibilityEvent) {
        val watching = watch ?: return
        if (event.eventType == AccessibilityEvent.TYPE_VIEW_TEXT_CHANGED && event.getSource(0) == watching.node) {
            handler.removeCallbacks(evaluate); handler.postDelayed(evaluate, SETTLE_MS)
        }
    }

    private fun evaluateCorrection() {
        val w = watch ?: return
        if (SystemClock.elapsedRealtime() > w.deadline) { disarmCorrection(); return }
        // Privacy metadata is rechecked before every read; password/sensitive metadata is checked by refreshNode before text.
        val info = inputMethod?.currentInputEditorInfo
        if (InsertionPolicy.privateEditor(w.baseline, info?.packageName, info?.inputType, info?.imeOptions ?: 0)) { disarmCorrection(); return }
        val current = refreshNode(w.node, w.baseline) ?: return
        // Keep watching while the user may still be mid-correction; one proposal per insertion.
        val proposal = DictionaryLearner.propose(w.inserted, w.baseline.text, current.text, w.dictionary) ?: return
        disarmCorrection()
        val book = ProposalBook.get(this)
        Thread { if (book.add(proposal)) Log.i("ParlaCapture", "learn proposed=true") }.start() // The words stay out of logs.
    }

    private fun refreshNode(node: AccessibilityNodeInfo, original: EditorSnapshot, log: CaptureLog = CaptureLog("edit")): EditorSnapshot? = runCatching {
        log.consent = hasConsent()
        if (log.consent != true || !node.refresh()) null else snapshot(node, log, original)
    }.onFailure { log.failure(it) }.getOrNull()

    private fun disarmCorrection() {
        watch = null; handler.removeCallbacks(evaluate); handler.removeCallbacks(giveUp)
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
        revokeEdits()
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
        invalidateAnchor(); disarmCorrection(); selection = false
        handler.removeCallbacksAndMessages(null)
        if (instance === this) {
            instance = null
            mutableConnected.value = false
            mutableKeyboardBounds.value = null
            mutableEditActions.value = EditActions()
        }
    }
}
