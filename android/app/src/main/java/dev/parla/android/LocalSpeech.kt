package dev.parla.android

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlin.math.sqrt
import kotlinx.coroutines.suspendCancellableCoroutine

internal interface SpeechNative {
    fun createToken(): Long
    fun cancel(token: Long)
    fun release(token: Long)
    fun recognize(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray?
}
internal object WhisperJni : SpeechNative {
    init { System.loadLibrary("parla-whisper") }
    external override fun createToken(): Long
    external override fun cancel(token: Long)
    external override fun release(token: Long)
    external override fun recognize(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray?
}
internal class LocalSpeech(private val native: SpeechNative = WhisperJni) {
    suspend fun transcribe(wav: File, model: File, catalog: SpeechModel, words: List<String>, language: String, validate: () -> Unit = {}): String = suspendCancellableCoroutine { c ->
        val revoked = AtomicBoolean(false)
        val token = native.createToken()
        c.invokeOnCancellation { revoked.set(true); native.cancel(token) }
        // Start outside the caller's cancellable job. Only actual native exit releases the token.
        nativeSubmit {
            try {
                if(revoked.get()) return@nativeSubmit
                validate()
                ModelCatalog.verify(model, catalog)
                val samples = WavInput.read(wav)
                if(revoked.get()) return@nativeSubmit
                validate()
                val bytes = native.recognize(token, model.absolutePath.toByteArray(Charsets.UTF_8), samples,
                    VocabularyHints.asrPrompt(words).toByteArray(Charsets.UTF_8), SpeechLanguagePolicy.language(catalog,language).toByteArray(Charsets.UTF_8))
                val text = bytes?.toString(Charsets.UTF_8)?.let(TextRules::stripNonSpeech).orEmpty().trim()
                if(c.isActive && !revoked.get()) {
                    if(text.isEmpty()) c.resumeWithException(IllegalStateException("No speech recognized. Try a longer recording closer to the microphone.")) else c.resume(text)
                }
            } catch(t: Throwable) { if(c.isActive && !revoked.get()) c.resumeWithException(t) }
            finally { native.release(token) }
        }
    }
    private fun nativeSubmit(work: () -> Unit) = NativeTasks.submit(work)
}
// Shared executor for all real native work and destructive model operations.
internal object NativeTasks {
    private val executor = Executors.newSingleThreadExecutor { r -> Thread(r,"parla-inference").apply { isDaemon = true } }
    fun submit(work: () -> Unit) { executor.execute(work) }
    suspend fun <T> run(work: () -> T): T = suspendCancellableCoroutine { c ->
        submit { try { val result = work(); if(c.isActive) c.resume(result) } catch(t: Throwable) { if(c.isActive) c.resumeWithException(t) } }
    }
}
internal object WavInput {
    const val MAX_BYTES = 16000 * 300 * 2 + 65536
    fun read(file: File, admitSpeech: Boolean = true): FloatArray {
        require(file.length() in 44L..MAX_BYTES.toLong()) { "Recording has an invalid size." }
        return parse(file.inputStream().use { it.readNBytes(MAX_BYTES+1) },admitSpeech)
    }
    fun parse(bytes: ByteArray, admitSpeech: Boolean = true): FloatArray {
        require(bytes.size in 44..MAX_BYTES) { "This recording cannot be read" }
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN)
        fun tag(i: Int) = String(bytes,i,4,Charsets.US_ASCII)
        fun u32(i: Int) = b.getInt(i).toLong() and 0xffffffffL
        require(tag(0) == "RIFF" && tag(8) == "WAVE" && u32(4) == bytes.size-8L) { "This recording is damaged" }
        var i = 12; var format = false; var data: IntRange? = null
        while(i+8 <= bytes.size) {
            val size = u32(i+4); val start = i+8; val end = start.toLong()+size
            require(end <= bytes.size && size <= MAX_BYTES) { "This recording is incomplete" }
            when(tag(i)) {
                "fmt " -> {
                    require(!format && size >= 16 && b.getShort(start).toInt() == 1 && b.getShort(start+2).toInt() == 1 && u32(start+4) == 16000L && u32(start+8) == 32000L && b.getShort(start+12).toInt() == 2 && b.getShort(start+14).toInt() == 16) { "This recording uses an unsupported audio format" }
                    format = true
                }
                "data" -> { require(data == null && size % 2 == 0L && size <= 16000*300*2) { "This recording contains invalid audio" }; data = start until end.toInt() }
            }
            i = (end + (size and 1)).toInt()
        }
        require(i == bytes.size && format && data != null) { "This recording is incomplete" }
        val range = data; val samples = FloatArray(range.count()/2) { index -> b.getShort(range.first+2*index)/32768f }
        var squares = 0.0; for(sample in samples) squares += sample.toDouble()*sample
        val rms = if(samples.isEmpty()) 0.0 else sqrt(squares/samples.size)
        require(samples.isNotEmpty()) { "Empty recording" }
        require(!admitSpeech || samples.size >= 6400 && rms >= 1e-4) { "Recording is too short or silent. Speak for at least half a second." }
        return samples
    }
}

internal object SpeechLanguagePolicy {
    fun language(model: SpeechModel, requested: String): String = when {
        model.id in setOf("base.en","small.en-q5_1") -> "en"
        requested in SpeechLanguages.codes -> requested
        else -> "auto"
    }
}
