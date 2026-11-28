package dev.parla.android

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.AudioTrack
import android.media.MediaRecorder
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.sqrt
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/** Desktop microphone test: RAM-only, at most 10 seconds, never transcribed, sent or saved. */
internal object MicTestPolicy {
    const val SAMPLE_RATE = 16_000
    const val MAX_SAMPLES = 160_000
    const val MAX_RUN_MS = 10_000L
    const val FIRST_PCM_DEADLINE_MS = 2_000L
    const val SIGNAL_RMS = 1e-4
    enum class State(val message: String) {
        idle("Tap Start test and say something."),
        starting("Starting…"),
        signal("Your microphone is working."),
        silent("No sound detected. Speak up or check your microphone."),
        noAudio("No audio received. Check your microphone and access."),
        stoppedBeforeAudio("Stopped before any audio arrived."),
        silenced("Another app is using the microphone. Stop its recording, then try again."),
    }
    /** Framework silencing wins: a silenced client still receives (zero) PCM that would read as quiet. */
    fun capture(samples: Int, signal: Boolean, silenced: Boolean, elapsedMs: Long, ended: Boolean): State = when {
        silenced -> State.silenced
        samples > 0 -> if(signal) State.signal else State.silent
        elapsedMs >= FIRST_PCM_DEADLINE_MS -> State.noAudio
        ended -> State.stoppedBeforeAudio
        else -> State.starting
    }
}

/**
 * One app-wide microphone owner. A coroutine Job holds it until the Job completes, which is after the
 * recorder's finally has released its AudioRecord (withContext waits for its block even when canceled).
 */
internal object MicrophoneOwner {
    private var owner: Job? = null
    @Synchronized fun acquire(job: Job): Boolean {
        if(owner != null && owner !== job) return false
        owner = job
        job.invokeOnCompletion { synchronized(this) { if(owner === job) owner = null } }
        return true
    }
}

internal data class MicTestView(val message: String = MicTestPolicy.State.idle.message, val detail: String = "", val level: Float = 0f, val samples: Int = 0,
    val capturing: Boolean = false, val playing: Boolean = false, val hasReview: Boolean = false)

internal class MicrophoneTest(context: Context) {
    private val app = context.applicationContext
    private val scope = CoroutineScope(SupervisorJob()+Dispatchers.Main.immediate)
    private val value = MutableStateFlow(MicTestView())
    val view = value.asStateFlow()
    private var job: Job? = null
    @Volatile private var stopRequested = AtomicBoolean(false)
    private var review = ShortArray(0)
    private var track: AudioTrack? = null

    fun start() {
        val previous = job
        clear()
        OriginalCopy.clear() // desktop: starting a microphone test clears the last original
        if(app.checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) { value.value = MicTestView("Allow microphone access in parla setup, then try again."); return }
        if(ParlaService.status.value.phase.let { it == Phase.RECORDING || it == Phase.PROCESSING }) { value.value = MicTestView("Finish the current dictation first."); return }
        val stop = AtomicBoolean(false); stopRequested = stop
        value.value = MicTestView(MicTestPolicy.State.starting.message,capturing = true)
        job = scope.launch {
            previous?.join() // a restarted test waits until the old recorder is released
            if(!MicrophoneOwner.acquire(coroutineContext.job)) { value.value = MicTestView("Finish the current dictation first."); return@launch }
            val captured = try { withContext(Dispatchers.IO) { capture(stop) } }
            catch(c: CancellationException) { throw c }
            catch(e: Exception) { value.value = MicTestView(e.message ?: "Couldn’t start the microphone. Check access and your device."); return@launch }
            review = captured
            value.update { it.copy(capturing = false,level = 0f,hasReview = captured.isNotEmpty(),detail = if(captured.isNotEmpty()) "Stopped. Tap Listen to hear it." else "") }
        }
    }

    @SuppressLint("MissingPermission") // Checked in start().
    private suspend fun capture(stop: AtomicBoolean): ShortArray {
        val minimum = AudioRecord.getMinBufferSize(MicTestPolicy.SAMPLE_RATE,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT)
        check(minimum > 0) { "This device cannot record in the required audio format." }
        val recorder = AudioRecord(MediaRecorder.AudioSource.MIC,MicTestPolicy.SAMPLE_RATE,AudioFormat.CHANNEL_IN_MONO,AudioFormat.ENCODING_PCM_16BIT,maxOf(minimum*2,4096))
        val buffer = ShortArray(MicTestPolicy.MAX_SAMPLES)
        var count = 0; var signal = false; var silenced = false
        val started = SystemClock.elapsedRealtime()
        fun publish(level: Float, ended: Boolean) {
            val state = MicTestPolicy.capture(count,signal,silenced,SystemClock.elapsedRealtime()-started,ended)
            if(stopRequested === stop) value.update { it.copy(message = state.message,level = level,samples = count) }
        }
        try {
            check(recorder.state == AudioRecord.STATE_INITIALIZED) { "The microphone is unavailable. Close other recording apps and try again." }
            recorder.startRecording()
            check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "Couldn’t start the microphone. Check access and your device." }
            while(!stop.get() && count < buffer.size && SystemClock.elapsedRealtime()-started < MicTestPolicy.MAX_RUN_MS) {
                currentCoroutineContext().ensureActive()
                val read = recorder.read(buffer,count,minOf(2048,buffer.size-count),AudioRecord.READ_NON_BLOCKING)
                check(read >= 0) { "The microphone disconnected." }
                // Only this recorder's own configuration decides; another active recorder alone is not contention.
                silenced = silenced || recorder.activeRecordingConfiguration?.isClientSilenced == true
                if(read == 0) { publish(0f,false); delay(10); continue }
                var squares = 0.0; for(i in count until count+read) squares += buffer[i].toDouble()*buffer[i]
                val rms = sqrt(squares/read)/32768.0
                signal = signal || rms > MicTestPolicy.SIGNAL_RMS
                count += read
                publish(sqrt(rms).toFloat().coerceIn(0f,1f),false) // display-only perceptual scale
            }
            publish(0f,true)
            return buffer.copyOf(count)
        } finally {
            runCatching { if(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) recorder.stop() }
            recorder.release()
        }
    }

    fun stop() { stopRequested.set(true) }

    fun listen() {
        if(value.value.capturing || review.isEmpty() || track != null) return
        val samples = review
        try {
            val t = AudioTrack.Builder()
                .setAudioAttributes(AudioAttributes.Builder().setUsage(AudioAttributes.USAGE_MEDIA).setContentType(AudioAttributes.CONTENT_TYPE_SPEECH).build())
                .setAudioFormat(AudioFormat.Builder().setEncoding(AudioFormat.ENCODING_PCM_16BIT).setSampleRate(MicTestPolicy.SAMPLE_RATE).setChannelMask(AudioFormat.CHANNEL_OUT_MONO).build())
                .setTransferMode(AudioTrack.MODE_STATIC).setBufferSizeInBytes(samples.size*2).build()
            track = t
            check(t.write(samples,0,samples.size) == samples.size)
            t.notificationMarkerPosition = samples.size
            t.setPlaybackPositionUpdateListener(object : AudioTrack.OnPlaybackPositionUpdateListener {
                override fun onMarkerReached(track: AudioTrack) { if(this@MicrophoneTest.track === track) stopListening() }
                override fun onPeriodicNotification(track: AudioTrack) {}
            },Handler(Looper.getMainLooper()))
            t.play()
            value.update { it.copy(playing = true,detail = "Playing…") }
        } catch(_: Exception) { stopListening(); value.update { it.copy(detail = "Couldn’t play the test. Try Listen again.") } }
    }

    fun stopListening() {
        track?.let { runCatching { it.stop() }; it.release() }; track = null
        value.update { it.copy(playing = false,detail = if(it.hasReview) "Stopped. Tap Listen to hear it." else "") }
    }

    fun clear() {
        stopRequested.set(true); job?.cancel(); job = null
        stopListening(); review = ShortArray(0)
        value.value = MicTestView()
    }

    fun close() { clear(); scope.cancel() }
}

@Composable internal fun MicrophoneTestScreen() {
    val context = LocalContext.current
    val test = remember { MicrophoneTest(context) }
    val view by test.view.collectAsState()
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(lifecycle) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _,event -> if(event == androidx.lifecycle.Lifecycle.Event.ON_STOP) test.clear() }
        lifecycle.lifecycle.addObserver(observer)
        onDispose { lifecycle.lifecycle.removeObserver(observer); test.close() }
    }
    Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),verticalArrangement = Arrangement.spacedBy(14.dp)) {
        Text("Test your microphone",style = MaterialTheme.typography.headlineMedium)
        Text("Records up to 10 seconds. The audio isn’t saved, transcribed or sent anywhere. Use headphones when you listen back.")
        Text(view.message)
        if(view.detail.isNotEmpty()) Text(view.detail,style = MaterialTheme.typography.bodySmall)
        LinearProgressIndicator(progress = { view.level },modifier = Modifier.fillMaxWidth())
        Text("%.1f of 10 seconds".format(view.samples/MicTestPolicy.SAMPLE_RATE.toDouble()),style = MaterialTheme.typography.bodySmall)
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            Button(onClick = test::start,enabled = !view.capturing) { Text("Start test") }
            TextButton(onClick = test::stop,enabled = view.capturing) { Text("Stop") }
            TextButton(onClick = { if(view.playing) test.stopListening() else test.listen() },enabled = !view.capturing && view.hasReview) { Text(if(view.playing) "Stop listening" else "Listen") }
            TextButton(onClick = test::clear) { Text("Clear") }
        }
        Text("Leaving this screen clears the test.",style = MaterialTheme.typography.bodySmall)
    }
}
