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

    override fun onCreate() {
        super.onCreate()
        // Orphaned private audio can remain only after OS/process termination.
        CaptureAudio.sweep(File(cacheDir, "audio"))
        CaptureAudio.sweep(File(cacheDir, "keyboard-audio")) // Previous keyboard cache; never active owners.
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, "parla dictation controls", NotificationManager.IMPORTANCE_LOW)
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
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
            // Armed while the activity is visible. AudioRecord exists only during an explicit session.
            val types = ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE or
                (if (Build.VERSION.SDK_INT >= 34) ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE else 0)
            startForeground(NOTIFICATION, notification(), types)
            bubble = BubbleWindow(this, ::toggle, ::beginRecording, ::stopRecording, ::cancelSession)
            bubble?.show()
            mutableVisible.value = true
            scope.launch { store.data.collect { bubble?.configure(it.settings) } }
            scope.launch { ParlaAccessibilityService.keyboardBounds.collect { bubble?.placeNearKeyboard(it) } }
            scope.launch { status.collect { bubble?.render(it); updateNotification() } }
            true
        } catch (_: Exception) {
            fail("Android could not show the bubble. Open parla and check permissions, then try again.")
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

    private fun beginRecording() {
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
        val anchor = owner.captureAnchor(false) { cancelSession() }
        if (anchor == null) { fail("Tap a non-sensitive text field, keep your keyboard open, then try again."); return }
        anchorOwner = owner
        capturedAnchor = anchor
        val effective = snapshot.forApp(anchor.snapshot.packageName)
        val settings = if (anchor.privateEditor) effective.settings.copy(noHistory = true) else effective.settings
        val frozen = effective.copy(settings = settings)
        val model = manager.selected(settings)
        if (model == null || !manager.file(model).isFile) {
            owner.release(anchor); capturedAnchor = null; anchorOwner = null
            fail("The effective speech model is missing. Open Models to download it."); openApp(); return
        }
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
        mutableStatus.value = DictationStatus(Phase.RECORDING, "Listening · tap to finish")
        val entered = java.util.concurrent.atomic.AtomicBoolean(false)
        session = scope.launch {
            entered.set(true)
            try {
                capture.record(file) { level ->
                    scope.launch {
                        if (recorder === capture && mutableStatus.value.phase == Phase.RECORDING) {
                            mutableStatus.value = mutableStatus.value.copy(level = level)
                        }
                    }
                }
                ensureActive()
                recovery.prepare(file,anchor.privateEditor) { op.revoked }
                ensureActive()
                val category = TextRules.category(anchor.snapshot.packageName)
                val singleLine = anchor.snapshot.inputType and 0x20000 == 0
                DictationFlow().run(op,frozen,category,singleLine,SystemClock.elapsedRealtime()-startedAt,
                    transcribe = {
                        LocalSpeech().transcribe(file,manager.file(model),model,frozen.dictionary,settings.language).also(recovery::recognized)
                    },
                    key = { store.readKey(settings) },
                    save = { entry, existing -> store.update { local ->
                        if(existing) local.copy(history = local.history.map { if(it.id == entry.id) entry else it })
                        else if(local.settings.noHistory) local else local.copy(history = listOf(entry)+local.history)
                    } },
                    deliver = { text, authorize -> owner.insert(anchor,text,authorize) },
                    stage = { stage, message -> if(!op.revoked) mutableStatus.value = DictationStatus(if(stage == PendingOperation.Stage.finished) Phase.IDLE else Phase.PROCESSING,message) })
            } catch (cancelled: CancellationException) {
                throw cancelled
            } catch (error: Exception) {
                if (!op.revoked) fail(error.message?.take(250) ?: "Local transcription failed. Check Models and device storage.")
            } finally {
                capture.stop()
                owner.release(anchor)
                withContext(NonCancellable + Dispatchers.IO) {
                    // LocalSpeech cancellation revokes immediately; its serial barrier proves actual JNI exit.
                    recovery.finish(op.revoked || anchor.privateEditor)
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
        mutableStatus.value = status.value.copy(phase = Phase.PROCESSING, message = "Finishing recording…", level = 0f)
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
        cancelSession()
        scope.cancel()
        bubble?.close()
        bubble = null
        mutableVisible.value = false
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
        private val mutableVisible = MutableStateFlow(false)
        val visible = mutableVisible.asStateFlow()
        fun command(context: Context, action: String) {
            val intent = Intent(context, ParlaService::class.java).setAction(action)
            if (action == SHOW || action == TOGGLE) context.startForegroundService(intent) else context.startService(intent)
        }
    }
}

