package dev.parla.android

import android.media.MediaPlayer
import java.io.File
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal interface RecoveryPlayer {
    fun play(file: File, completed: (Boolean) -> Unit)
    /** Returns only after the local player has released its reader. */
    fun stop()
}
internal class AndroidRecoveryPlayer : RecoveryPlayer {
    private var player: MediaPlayer? = null
    override fun play(file: File, completed: (Boolean) -> Unit) {
        stop()
        val p = MediaPlayer(); player = p
        try {
            p.setDataSource(file.absolutePath)
            p.setOnCompletionListener { stop(); completed(true) }
            p.setOnErrorListener { _,_,_ -> stop(); completed(false); true }
            p.prepare(); p.start()
        } catch(t: Throwable) { stop(); throw t }
    }
    override fun stop() { player?.release(); player = null }
}
internal class RecoveryPlayback(private val recordings: RecordingStore, private val factory: () -> RecoveryPlayer = ::AndroidRecoveryPlayer) {
    private var player: RecoveryPlayer? = null
    private var lease: RecordingStore.Lease? = null
    val id get() = lease?.file?.name
    fun start(id: String, finished: (Boolean) -> Unit) {
        stop()
        val owned = recordings.acquire(id); lease = owned
        try {
            recordings.validate(owned)
            val next = factory(); player = next
            next.play(owned.file) { success ->
                // Stale platform callbacks cannot stop/release a newer reader.
                if(lease === owned) { stop(); finished(success) }
            }
        } catch(t: Throwable) { stop(); throw t }
    }
    fun stop() {
        player?.stop(); player = null
        lease?.let(recordings::release); lease = null
    }
}
internal data class AudioPreview(val sourceID: String, val text: String, val saved: Boolean = false)
internal data class AudioRecoveryState(val activeID: String? = null, val stopping: Boolean = false, val preview: AudioPreview? = null, val message: String = "")
internal fun interface RecoveryRecognizer {
    suspend fun recognize(audio: File, modelFile: File, model: SpeechModel, data: LocalData, validate: () -> Unit): String
}
/** Actual UI controller: local recognition only; no provider, cleanup or editor dependency. */
internal class AudioRecovery(
    private val recordings: RecordingStore,
    private val current: () -> LocalData?,
    private val modelFile: (SpeechModel) -> File,
    private val save: (HistoryEntry) -> Boolean,
    private val recognizer: RecoveryRecognizer = RecoveryRecognizer { audio,file,model,data,validate ->
        LocalSpeech().transcribe(audio,file,model,data.dictionary,data.settings.language,validate)
    },
    dispatcher: CoroutineDispatcher = Dispatchers.Main.immediate,
    private val drain: suspend () -> Unit = { withContext(NonCancellable) { NativeTasks.run { } } },
    private val catalog: List<SpeechModel> = ModelCatalog.all,
) {
    private val scope = CoroutineScope(SupervisorJob()+dispatcher)
    private val value = MutableStateFlow(AudioRecoveryState())
    val state = value.asStateFlow()
    private var job: Job? = null
    private var lease: RecordingStore.Lease? = null
    fun transcribe(id: String) {
        if(job?.isCompleted == false) return
        val frozen = current() ?: run { value.value = value.value.copy(message = "Repair current settings before retranscription. No fallback request ran."); return }
        val model = catalog.firstOrNull { it.id == frozen.settings.localModel }
            ?: run { value.value = value.value.copy(message = "Choose an installed global speech model in Models."); return }
        val owned = try { recordings.acquire(id) } catch(_: Exception) { value.value = value.value.copy(message = "Recording is busy, expired or unavailable. Refresh and check settings."); return }
        lease = owned
        value.value = AudioRecoveryState(activeID = id,message = "Transcribing locally with current global model, language and priority vocabulary…")
        val work = scope.launch(start = CoroutineStart.LAZY) {
            try {
                val raw = recognizer.recognize(owned.file,modelFile(model),model,frozen) {
                    check(current() != null) { "Current settings unavailable." }; recordings.validate(owned)
                }
                ensureActive(); recordings.validate(owned)
                check(raw.isNotBlank())
                // Preview belongs to this screen; retain its source across navigation/recreation.
                value.value = AudioRecoveryState(activeID = id,preview = AudioPreview(id,raw),message = "Original transcript ready. No cleanup, provider or insertion ran. Source audio remains until explicit deletion or retention expiry.")
            } catch(_: CancellationException) {
                value.value = AudioRecoveryState(activeID = id,stopping = true,message = "Canceling · waiting for local reader to exit. Original audio preserved.")
            } catch(_: Exception) {
                value.value = AudioRecoveryState(activeID = id,message = "Local recognition failed. Original audio preserved; no provider or insertion ran.")
            } finally {
                withContext(NonCancellable) {
                    drain()
                    // Recovery previews are ephemeral. Only explicit Delete/Clear or expiry disposes
                    // this source, so navigation to enable history never destroys both text and audio.
                    recordings.release(owned)
                }
                if(lease === owned) { lease = null; value.value = value.value.copy(activeID = null,stopping = false) }
            }
        }
        job = work
        work.invokeOnCompletion {
            // Cancellation before dispatch still relinquishes this generation only.
            recordings.release(owned)
            if(lease === owned) { lease = null; value.value = value.value.copy(activeID = null,stopping = false) }
        }
        work.start()
    }
    fun cancel() {
        lease?.let(recordings::revoke); job?.cancel()
        value.value = value.value.copy(preview = null,message = "Preview canceled. Original audio preserved when still available.")
    }
    fun savePreview() {
        val p = value.value.preview ?: return
        val settings = current()?.settings
        if(settings == null || settings.noHistory) {
            value.value = value.value.copy(message = "Repair current settings and enable text history before Save. Copy remains available."); return
        }
        if(p.saved) return
        if(save(HistoryEntry(raw = p.text,text = p.text,note = "Explicitly saved local audio recovery; no insertion attempted."))) {
            value.value = value.value.copy(preview = p.copy(saved = true),message = "Raw transcript saved under the current history count limit.")
        } else value.value = value.value.copy(message = "Text was not saved. Preview remains available to copy or retry Save.")
    }
    fun close() { cancel(); scope.cancel() }
    suspend fun waitForExit() { job?.join() }
}

/** Service capture ownership: usable raw is ASR success, independent of later cleanup/insertion. */
internal class CaptureRecovery(
    private val recordings: RecordingStore,
    private val drain: suspend () -> Unit = { NativeTasks.run { } },
) {
    @Volatile private var lease: RecordingStore.Lease? = null
    private var recognized = false
    suspend fun prepare(file: File, privateSession: Boolean, canceled: () -> Boolean) {
        // Assign ownership inside the noncancellable block; canceled dispatcher return cannot lose the lease.
        withContext(NonCancellable + Dispatchers.IO) {
            lease = recordings.stash(file,privateSession || canceled())
            if(canceled()) cancel()
        }
    }
    fun recognized(raw: String) { recognized = raw.isNotBlank() }
    fun cancel() { lease?.let(recordings::cancelCapture) }
    suspend fun finish(canceledOrPrivate: Boolean) {
        withContext(NonCancellable + Dispatchers.IO) {
            drain() // actual native exit, including a canceled continuation
            recordings.resolve(lease,recognized,canceledOrPrivate)
            lease = null
        }
    }
}
