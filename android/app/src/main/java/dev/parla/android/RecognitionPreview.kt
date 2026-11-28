package dev.parla.android

import android.app.ActivityManager
import android.content.Context
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Draft text while recording (desktop's optional pill preview). Off by default: every pass is a whole small-model
 * load and decode on the shared serial native executor. The draft is shown, never inserted or saved.
 */
internal object PreviewPolicy {
    /** Smallest catalog model; the draft never uses the (possibly large) dictation model. */
    val model get() = ModelCatalog.all.first { it.id == "base.en" }
    const val MIN_MEMORY_BYTES = 3_500_000_000L // a nominal 4 GB phone reports about 3.6 GB
    const val MIN_CORES = 6
    data class Device(val lowRam: Boolean, val totalMemory: Long, val cores: Int)
    fun device(context: Context): Device {
        val am = context.getSystemService(ActivityManager::class.java)
        val info = ActivityManager.MemoryInfo().also(am::getMemoryInfo)
        return Device(am.isLowRamDevice,info.totalMem,Runtime.getRuntime().availableProcessors())
    }
    /** Why this phone cannot offer the preview at all, or null. */
    fun unsupported(d: Device): String? = when {
        d.lowRam || d.totalMemory < MIN_MEMORY_BYTES -> "This phone doesn’t have enough memory for a draft preview."
        d.cores < MIN_CORES -> "This phone’s processor is too slow for a draft preview."
        else -> null
    }
    /** Why the preview will not run for these settings, or null when it will. */
    fun blocked(s: Settings, d: Device, modelInstalled: Boolean): String? = unsupported(d) ?: when {
        !modelInstalled -> "Download Base (English) to use the draft preview."
        s.language != "auto" && s.language != "en" -> "The draft preview works only for English."
        else -> null
    }
    fun active(s: Settings, d: Device, modelInstalled: Boolean) = s.previewEnabled && blocked(s,d,modelInstalled) == null
}

/** Runs [record] with [draft] alongside it. The draft is canceled when [record] returns or throws. */
internal suspend fun <T> recordWithDraft(draft: (suspend () -> Unit)?, record: suspend () -> T): T = coroutineScope {
    val drafting = draft?.let { launch { it() } }
    try { record() } finally { drafting?.cancel() }
}

/** One pass at a time, awaited, so the queue never holds more than one draft ahead of the final recognition. */
internal class RecognitionPreview(private val speech: LocalSpeech = LocalSpeech(), private val intervalMs: Long = 1500) {
    suspend fun run(recording: File, modelFile: File, model: SpeechModel, words: List<String>, publish: (String) -> Unit) {
        var verified = false
        while(true) {
            delay(intervalMs)
            val samples = withContext(Dispatchers.IO) { runCatching { tail(recording) }.getOrNull() } ?: continue
            if(samples.size < 16000) continue // under a second says nothing useful yet
            val text = try { speech.draft(samples,modelFile,model,words,"en",verify = !verified) }
                catch(c: CancellationException) { throw c }
                catch(_: Exception) { return } // missing, paused or failing model: stop drafting, never the recording
            verified = true
            publish(text)
        }
    }
    companion object {
        const val WINDOW_SAMPLES = 16000*30 // whisper's own window; longer recordings preview their latest 30 s
        /** The PCM written so far by WavRecorder (44-byte header first, data appended unbuffered). */
        fun tail(file: File): FloatArray {
            RandomAccessFile(file,"r").use { f ->
                val data = (f.length()-44).coerceAtLeast(0) and 1L.inv()
                val bytes = minOf(data,WINDOW_SAMPLES*2L).toInt()
                val raw = ByteArray(bytes); f.seek(44+data-bytes); f.readFully(raw)
                val b = ByteBuffer.wrap(raw).order(ByteOrder.LITTLE_ENDIAN)
                return FloatArray(bytes/2) { b.getShort(it*2)/32768f }
            }
        }
    }
}
