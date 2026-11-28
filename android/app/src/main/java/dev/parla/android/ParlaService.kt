package dev.parla.android

import android.Manifest
import android.app.*
import android.content.*
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.*
import android.provider.Settings as AndroidSettings
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import java.io.File

/** One foreground service owns the overlay and one cancellable session at a time. */
class ParlaService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val store by lazy { Store.get(this) }
    private var bubble: BubbleWindow? = null
    private var session: Job? = null
    private var operation: PendingOperation? = null
    private var recorder: WavRecorder? = null
    private var recoveryCapture: CaptureRecovery? = null
    private var audio: File? = null
    private var startedAt = 0L
    private var stopping = false
    private var anchorOwner: ParlaAccessibilityService? = null
    private var capturedAnchor: EditorAnchor? = null
    // Only this service creates the kept original, so it owns its suspend-safe expiry (see OriginalCopyOwner.screenChanged).
    private val screen = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) { OriginalCopy.screenChanged(intent.action == Intent.ACTION_SCREEN_OFF) }
    }

    override fun onCreate() {
        super.onCreate()
        SafeStart.get(this) // Counts a native attempt an earlier process never finished, before any new one.
        // Orphaned private audio can remain only after OS/process termination.
        CaptureAudio.sweep(File(cacheDir, "audio"))
        CaptureAudio.sweep(File(cacheDir, "keyboard-audio")) // Previous keyboard cache; never active owners.
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "parla dictation controls", NotificationManager.IMPORTANCE_LOW)
        )
        registerReceiver(screen, IntentFilter().apply { addAction(Intent.ACTION_SCREEN_OFF); addAction(Intent.ACTION_SCREEN_ON); addAction(Intent.ACTION_USER_PRESENT) }, RECEIVER_NOT_EXPORTED)
        OriginalCopy.interactive = getSystemService(android.os.PowerManager::class.java).isInteractive
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action != HIDE && intent?.action != CANCEL && !requireAccessibilityConsent()) return START_NOT_STICKY
        when (intent?.action) {
            HIDE -> { cancelSession(); stopSelf() }
            CANCEL -> cancelSession()
            STOP -> stopRecording()
            else -> {
                if (!activate()) return START_NOT_STICKY
                if (intent?.action == TOGGLE) toggle()
            }
        }
        return START_NOT_STICKY
    }

    private fun activate(): Boolean {
        if (bubble != null) return true
        if (!AndroidSettings.canDrawOverlays(this) || checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            fail("Allow microphone and display over apps in parla setup.")
            stopSelf()
            return false
        }
        return try {
            // Armed by the visible activity after setup. AudioRecord exists only during an explicit session.
            val types = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                (if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0)
            startForeground(NOTIFICATION, notification(), types)
            bubble = BubbleWindow(this, ::toggle, { beginRecording() }, ::stopRecording, ::cancelSession, ::action)
            mutableArmed.value = true
            scope.launch { store.data.collect { bubble?.configure(it.settings) } }
            scope.launch {
                combine(ParlaAccessibilityService.editActions, store.data, status) { edits, data, state ->
                    if (state.phase == Phase.RECORDING || state.phase == Phase.PROCESSING) emptyList() else listOfNotNull(
                        BubbleAction.COMMAND.takeIf { edits.selection },
                        BubbleAction.PRESET.takeIf { edits.selection && data.presets.any { it.id == data.settings.selectedPresetID } },
                        BubbleAction.UNDO.takeIf { edits.undo },
                        BubbleAction.ORIGINAL.takeIf { edits.restore })
                }.collect { bubble?.setActions(it) }
            }
            scope.launch {
                // Armed is service readiness; attached is whether the control is on screen right now.
                combine(ParlaAccessibilityService.keyboardBounds, ParlaAccessibilityService.connected, ::Pair).collect { (keyboard, connected) ->
                    bubble?.placeNearKeyboard(keyboard)
                    val attach = BubbleVisibility.attached(keyboard, store.accessibilityConsentGranted, connected,
                        AndroidSettings.canDrawOverlays(this@ParlaService),
                        checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
                    // No keyboard means no target: cancel capture. Processing keeps its captured field and never retargets.
                    if (!attach && status.value.phase == Phase.RECORDING) cancelSession()
                    bubble?.setVisible(attach)
                }
            }
            scope.launch { status.collect { bubble?.render(it); updateNotification() } }
            true
        } catch (_: Exception) {
            fail("Could not show the voice control. Open parla to check permissions, then try again.")
            stopSelf()
            false
        }
    }

    private fun toggle() {
        when (status.value.phase) {
            Phase.RECORDING -> stopRecording()
            Phase.PROCESSING -> Unit
            else -> beginRecording()
        }
    }

    private fun action(action: BubbleAction) {
        when (action) {
            BubbleAction.COMMAND -> beginRecording(command = true)
            BubbleAction.PRESET -> runPreset()
            BubbleAction.UNDO, BubbleAction.ORIGINAL -> {
                if (!requireAccessibilityConsent() || session?.isCompleted == false) return
                val owner = ParlaAccessibilityService.instance ?: return
                scope.launch {
                    val outcome = owner.edit(if (action == BubbleAction.UNDO) GuardedEdits.Action.undo else GuardedEdits.Action.restoreOriginal)
                    mutableStatus.value = DictationStatus(Phase.IDLE, outcome)
                }
            }
        }
    }

    /** The anchor for a capture, or null after reporting why. Selected-text changes need a non-empty selection. */
    private fun capture(owner: ParlaAccessibilityService, selected: Boolean): EditorAnchor? {
        val anchor = owner.captureAnchor({ pkg -> !selected && NearbyText.granted(store.data.value, pkg) }, selected) { cancelSession() }
        if (anchor == null) fail(if (selected) "Select text in a non-sensitive field, keep your keyboard open, then try again."
            else "Tap a non-sensitive text field, keep your keyboard open, then try again.")
        return anchor
    }

    /** Mac runSelectedPreset: the selected preset's exact intent applied to the frozen selection, no microphone. */
    private fun runPreset() {
        if (!requireAccessibilityConsent()) return
        if (session?.isCompleted == false || stopping) return
        if (!store.ready) { fail("Reload or repair local data in Settings → Data recovery."); openApp("Data recovery"); return }
        val owner = ParlaAccessibilityService.instance ?: run { fail("Enable parla text insertion in accessibility settings, then return to your text field."); return }
        val anchor = capture(owner, selected = true) ?: return
        val effective = store.data.value.forApp(anchor.snapshot.packageName)
        val frozen = if (anchor.privateEditor) effective.copy(settings = effective.settings.copy(noHistory = true, keepLastOriginal = false)) else effective
        val instruction = runCatching { Pipeline().selectedIntent(frozen) }.getOrElse {
            owner.release(anchor); fail(it.message ?: "Choose a saved preset in Output settings."); return
        }
        val selection = anchor.snapshot.text.substring(minOf(anchor.snapshot.selectionStart, anchor.snapshot.selectionEnd), maxOf(anchor.snapshot.selectionStart, anchor.snapshot.selectionEnd))
        val op = PendingOperation(); operation = op; anchorOwner = owner; capturedAnchor = anchor
        mutableStatus.value = DictationStatus(Phase.PROCESSING, "Changing selected text…")
        session = scope.launch {
            try {
                op.advance(PendingOperation.Stage.recognizing)
                transformFlow(op, owner, anchor, frozen, selection, 0) { instruction }
            } catch (cancelled: CancellationException) { throw cancelled
            } catch (error: Exception) { if (!op.revoked) fail(error.message?.take(250) ?: "Couldn’t change the selected text.")
            } finally {
                owner.release(anchor)
                if (operation === op) { operation = null; capturedAnchor = null; anchorOwner = null }
            }
        }
    }

    private suspend fun transformFlow(op: PendingOperation, owner: ParlaAccessibilityService, anchor: EditorAnchor, frozen: LocalData,
                                      selection: String, duration: Long, instruction: suspend () -> String) {
        var spoken = ""
        DictationFlow().run(op, frozen, TextRules.category(anchor.snapshot.packageName), anchor.snapshot.inputType and 0x20000 == 0, duration,
            transcribe = { spoken = instruction(); selection },
            key = store::readKey, save = ::saveHistory,
            deliver = { text, authorize -> owner.insert(anchor, text, authorize, learn = frozen.dictionary.takeUnless { anchor.privateEditor }) },
            stage = { stage, message -> if (!op.revoked) mutableStatus.value = DictationStatus(if (stage == PendingOperation.Stage.finished) Phase.IDLE else Phase.PROCESSING, message) },
            app = anchor.snapshot.packageName,
            transform = { source, key -> Pipeline().transform(source, spoken, frozen, key) })
    }

    private fun saveHistory(entry: HistoryEntry, existing: Boolean) = store.update { local ->
        if (existing) local.copy(history = local.history.map { if (it.id == entry.id) entry else it })
        else if (local.settings.noHistory) local else local.copy(history = listOf(entry) + local.history)
    }

    private fun beginRecording(command: Boolean = false) {
        if (!requireAccessibilityConsent()) return
        if (session?.isCompleted == false || stopping) return
        val snapshot = store.data.value
        if (!store.ready) { fail("Reload or repair local data in Settings → Data recovery."); openApp("Data recovery"); return }
        val manager = ModelManager.get(this)
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            fail("Microphone permission is missing. Open parla setup to allow it."); return
        }
        val owner = ParlaAccessibilityService.instance
        if (owner == null) {
            fail("Enable parla text insertion in accessibility settings, then return to your text field."); return
        }
        val anchor = capture(owner, command) ?: return
        anchorOwner = owner
        capturedAnchor = anchor
        val effective = snapshot.forApp(anchor.snapshot.packageName)
        val settings = if (anchor.privateEditor) effective.settings.copy(noHistory = true, keepLastOriginal = false) else effective.settings
        val frozen = effective.copy(settings = settings)
        val model = manager.selected(settings)
        if (model == null || !manager.file(model).isFile) {
            owner.release(anchor); capturedAnchor = null; anchorOwner = null
            fail("Your speech model is missing. Download it in Models."); openApp(); return
        }
        OriginalCopy.clear() // a new capture replaces the previous dictation's original
        if (SafeStart.get(this).paused(model)) {
            // Refuse before listening, so no speech is recorded only to be refused.
            owner.release(anchor); capturedAnchor = null; anchorOwner = null
            fail(SafeStart.PAUSED); openApp(); return
        }
        val previewModel = PreviewPolicy.model
        val preview = PreviewPolicy.active(settings, PreviewPolicy.device(this), manager.file(previewModel).isFile)
        val op = PendingOperation(); operation = op
        op.advance(PendingOperation.Stage.recording)
        val file = CaptureAudio.reserve(File(cacheDir, "audio"))
        val recordings = RecordingStore.get(this)
        val recovery = CaptureRecovery(recordings)
        recoveryCapture = recovery
        audio = file
        val capture = WavRecorder(this)
        recorder = capture
        startedAt = SystemClock.elapsedRealtime()
        mutableStatus.value = DictationStatus(Phase.RECORDING, if (command) "Say how to change the selected text · tap to finish" else "Listening · tap to finish")
        val entered = java.util.concurrent.atomic.AtomicBoolean(false)
        val timing = TimingSession()
        session = scope.launch {
            entered.set(true)
            try {
                check(MicrophoneOwner.acquire(coroutineContext.job)) { "Finish the microphone test in parla, then try again." }
                // The draft ends with the recording on every path, before the final recognition is queued behind it.
                val draft: (suspend () -> Unit)? = if (preview) ({
                    RecognitionPreview().run(file, manager.file(previewModel), previewModel, frozen.dictionary) { text ->
                        if (recorder === capture && mutableStatus.value.phase == Phase.RECORDING) mutableStatus.value = mutableStatus.value.copy(draft = text.takeLast(200))
                    }
                }) else null
                recordWithDraft(draft) {
                    timing.span(TimingStage.record_start, TimingStage.record_stop) {
                        capture.record(file) { level ->
                            scope.launch {
                                if (recorder === capture && mutableStatus.value.phase == Phase.RECORDING) {
                                    mutableStatus.value = mutableStatus.value.copy(level = level)
                                }
                            }
                        }
                    }
                }
                ensureActive()
                // A spoken command is an instruction, not dictation: its audio is never kept for recovery.
                recovery.prepare(file,anchor.privateEditor || command) { op.revoked }
                ensureActive()
                val category = TextRules.category(anchor.snapshot.packageName)
                val singleLine = anchor.snapshot.inputType and 0x20000 == 0
                val speech: suspend () -> String = {
                    LocalSpeech().transcribe(file,manager.file(model),model,frozen.dictionary,settings.language).also(recovery::recognized)
                }
                val elapsed = SystemClock.elapsedRealtime()-startedAt
                val editor = anchor.snapshot
                if (command) transformFlow(op, owner, anchor, frozen,
                    editor.text.substring(minOf(editor.selectionStart, editor.selectionEnd), maxOf(editor.selectionStart, editor.selectionEnd)), elapsed, speech)
                else {
                    var spoken = ""
                    // Re-checked against live settings before sending and before accepting the reply.
                    val nearby = anchor.context.takeIf { it.isNotEmpty() }?.let { prefix ->
                        NearbyContext(prefix) { anchor.valid && NearbyText.granted(store.data.value, editor.packageName) }
                    }
                    DictationFlow().run(op,frozen,category,singleLine,elapsed,
                        transcribe = { speech().also { spoken = it } },
                        key = store::readKey, failover = store.data, save = ::saveHistory,
                        deliver = { text, authorize -> owner.insert(anchor,text,authorize,
                            original = spoken.takeIf { frozen.settings.outputMode != "selectedPreset" },
                            // Mac no-learning: a capture that read nearby text never teaches the dictionary.
                            learn = frozen.dictionary.takeIf { !anchor.privateEditor && anchor.context.isEmpty() }) },
                        stage = { stage, message -> if(!op.revoked) mutableStatus.value = DictationStatus(if(stage == PendingOperation.Stage.finished) Phase.IDLE else Phase.PROCESSING,message) },
                        timing = timing, app = editor.packageName, nearby = nearby)
                }
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                if (!op.revoked) fail(error.message?.take(250) ?: "Local transcription failed. Check Models and device storage.")
            } finally {
                capture.stop()
                owner.release(anchor)
                withContext(NonCancellable + Dispatchers.IO) {
                    // LocalSpeech cancellation revokes immediately; its serial barrier proves actual JNI exit.
                    recovery.finish(op.revoked || anchor.privateEditor || command)
                    CaptureAudio.release(file)
                }
                recorder = null
                audio = null
                stopping = false
                capturedAnchor = null
                anchorOwner = null
                if (operation === op) { operation = null }
                if(recoveryCapture === recovery) recoveryCapture = null
            }
        }
        session?.invokeOnCompletion {
            if(!entered.get()) {
                CaptureAudio.release(file); owner.release(anchor)
                if(operation === op) { operation = null; recorder = null; audio = null; stopping = false; capturedAnchor = null; anchorOwner = null; recoveryCapture = null }
            }
        }
    }

    private fun stopRecording() {
        if (status.value.phase != Phase.RECORDING || stopping) return
        stopping = true
        mutableStatus.value = status.value.copy(phase = Phase.PROCESSING, message = "Finishing recording…", level = 0f, draft = "")
        recorder?.stop()
    }

    private fun cancelSession() {
        val op = operation
        val attempted = op?.revoke() == true
        recoveryCapture?.cancel()
        val entryID = op?.prepared?.id
        capturedAnchor?.let { anchorOwner?.release(it) }
        capturedAnchor = null; anchorOwner = null
        recorder?.stop(); session?.cancel()
        val message = DictationFlow.cancellationMessage(attempted)
        if(op != null) RecoveryVault.outcome(op.id,message)
        if(attempted) entryID?.let { id -> store.update { local -> local.copy(history = local.history.map { if(it.id == id) it.copy(note = message) else it }) } }
        mutableStatus.value = DictationStatus(Phase.IDLE,message)
    }

    private fun fail(message: String) { mutableStatus.value = DictationStatus(Phase.ERROR, message) }
    private fun requireAccessibilityConsent(): Boolean {
        if (store.accessibilityConsentGranted) return true
        cancelSession()
        fail("Allow text insertion in parla setup first.")
        openApp("Setup")
        stopSelf()
        return false
    }
    private fun openApp(route: String = "Models") { runCatching { startActivity(Intent(this, MainActivity::class.java).putExtra("route",route).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)) } }
    private fun pending(action: String, code: Int) = PendingIntent.getService(this, code, Intent(this, ParlaService::class.java).setAction(action), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    private fun notification(): Notification {
        val state = status.value
        return NotificationCompat.Builder(this, CHANNEL)
            .setSmallIcon(dev.parla.android.R.drawable.ic_parla_mark)
            .setContentTitle(if (state.phase == Phase.RECORDING) "parla is listening" else "parla dictation")
            .setContentText(state.message)
            .setContentIntent(PendingIntent.getActivity(this, 0, Intent(this, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE))
            .setOngoing(true).setSilent(true).setOnlyAlertOnce(true)
            .addAction(0, if (state.phase == Phase.RECORDING) "Finish" else "Cancel", pending(if (state.phase == Phase.RECORDING) STOP else CANCEL, 1))
            .addAction(0, "Stop parla", pending(HIDE, 2)).build()
    }
    private fun updateNotification() { if (bubble != null) getSystemService(NotificationManager::class.java).notify(NOTIFICATION, notification()) }
    override fun onBind(intent: Intent?) = null
    override fun onDestroy() {
        unregisterReceiver(screen)
        OriginalCopy.clear() // nothing would observe screen-off any more
        cancelSession()
        scope.cancel()
        bubble?.close()
        bubble = null
        mutableArmed.value = false
        stopForeground(STOP_FOREGROUND_REMOVE)
        super.onDestroy()
    }

    override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
        super.onConfigurationChanged(newConfig)
        bubble?.refreshPlacement()
    }

    companion object {
        const val SHOW = "dev.parla.SHOW"
        const val TOGGLE = "dev.parla.TOGGLE"
        const val STOP = "dev.parla.STOP"
        const val CANCEL = "dev.parla.CANCEL"
        const val HIDE = "dev.parla.HIDE"
        private const val CHANNEL = "parla_dictation"
        private const val NOTIFICATION = 10
        private val mutableStatus = MutableStateFlow(DictationStatus())
        val status = mutableStatus.asStateFlow()
        private val mutableArmed = MutableStateFlow(false)
        /** The service is running and ready; the control itself appears only while a keyboard is open. */
        val armed = mutableArmed.asStateFlow()
        fun command(context: Context, action: String) {
            if ((action == SHOW || action == TOGGLE) && !Store.get(context).accessibilityConsentGranted) {
                context.startActivity(Intent(context, MainActivity::class.java).putExtra("route", "Setup")
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP))
                return
            }
            val intent = Intent(context, ParlaService::class.java).setAction(action)
            if (action == SHOW || action == TOGGLE) context.startForegroundService(intent) else context.startService(intent)
        }
    }
}

