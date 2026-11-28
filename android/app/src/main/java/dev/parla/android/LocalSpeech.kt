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
    /** [NativeSegments] payload: raw native segments with whisper 10 ms ticks. */
    fun recognizeTimed(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray? = throw IllegalStateException("Timestamps aren't available.")
    /** Load and free the model with no audio (Safe Start's "Try loading once"). False: whisper refused the file. */
    fun prepare(model: ByteArray): Boolean = error("Loading without audio is unavailable.")
    /** The last recognize's native init and whisper_full milliseconds (-1: not reached). Same serial executor. */
    fun lastTimings(): LongArray? = null
}
internal object WhisperJni : SpeechNative {
    init { System.loadLibrary("parla-whisper") }
    external override fun createToken(): Long
    external override fun cancel(token: Long)
    external override fun release(token: Long)
    external override fun recognize(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray?
    external override fun recognizeTimed(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray?
    external override fun prepare(model: ByteArray): Boolean
    external override fun lastTimings(): LongArray?
}
/** Mac RecognitionSegments.Cue: literal native segment text and whisper 1.9.1 PCM ticks (10 ms from sample zero). */
internal data class Cue(val text: String, val start: Long, val end: Long)
/** [cues] is null when native timing was refused; the independently bounded raw text is kept (Mac copyTimedResult). */
internal data class TimedTranscript(val text: String, val sampleCount: Int, val cues: List<Cue>?)

/** Parses and validates the bridge's timed payload. Structural damage throws; a timing refusal only drops [cues]. */
internal object NativeSegments {
    const val MAX_COUNT = 10_000
    const val MAX_BYTES = 1_048_576
    class Parsed(val raw: ByteArray, val cues: List<Cue>?)
    fun parse(payload: ByteArray, sampleCount: Int): Parsed {
        val b = java.nio.ByteBuffer.wrap(payload).order(java.nio.ByteOrder.LITTLE_ENDIAN)
        fun need(n: Long) = check(n >= 0 && b.remaining() >= n) { "On-device transcription failed" }
        need(4); val count = b.int.toLong() and 0xffffffffL
        check(count <= MAX_COUNT) { "The timed transcript is too large." }
        val raw = java.io.ByteArrayOutputStream()
        val segments = ArrayList<Triple<ByteArray, Long, Long>>(count.toInt())
        repeat(count.toInt()) {
            need(20); val start = b.long; val end = b.long; val length = b.int.toLong() and 0xffffffffL
            check(raw.size() + length <= MAX_BYTES) { "The timed transcript is too large." }
            need(length); val bytes = ByteArray(length.toInt()).also { b.get(it) }
            raw.write(bytes); segments += Triple(bytes, start, end)
        }
        check(!b.hasRemaining()) { "On-device transcription failed" }
        return Parsed(raw.toByteArray(), runCatching { validate(segments, sampleCount) }.getOrNull())
    }
    /** Mac RecognitionSegments.init: bounded count/bytes, start >= 0, end > start, both within the source, starts never decrease. */
    fun validate(segments: List<Triple<ByteArray, Long, Long>>, sampleCount: Int): List<Cue> {
        require(sampleCount > 0 && segments.size <= MAX_COUNT && segments.sumOf { it.first.size.toLong() } <= MAX_BYTES)
        var previous = 0L
        return segments.map { (bytes, start, end) ->
            require(start >= 0 && end > start && end <= sampleCount / 160 && start >= previous)
            previous = start
            // Strict UTF-8: a malformed native string refuses timing instead of being repaired.
            Cue(Charsets.UTF_8.newDecoder().decode(java.nio.ByteBuffer.wrap(bytes)).toString(), start, end)
        }
    }
}
internal class LocalSpeech(private val native: SpeechNative = WhisperJni, private val safeStart: SafeStart? = SafeStart.current) {
    suspend fun transcribe(wav: File, model: File, catalog: SpeechModel, words: List<String>, language: String, validate: () -> Unit = {}, timing: TimingSession? = null): String =
        recognize(model, catalog, words, language, validate, timing = timing) { WavInput.read(wav) }
    /** Already-decoded 16 kHz mono PCM (file import). Same admission and ceiling as recorded WAV. */
    suspend fun transcribe(samples: FloatArray, model: File, catalog: SpeechModel, words: List<String>, language: String, validate: () -> Unit = {}, timing: TimingSession? = null): String =
        recognize(model, catalog, words, language, validate, timing = timing) { WavInput.admit(samples, "This file is too short or silent. Use at least 0.4 seconds of speech."); samples }
    /** Explicit timed import: same admission and serial native owner; the text is the joined raw segments. */
    suspend fun transcribeTimed(samples: FloatArray, model: File, catalog: SpeechModel, words: List<String>, language: String, timing: TimingSession? = null): TimedTranscript {
        var cues: List<Cue>? = null
        val text = recognize(model, catalog, words, language, {}, timing = timing, run = native::recognizeTimed,
            raw = { payload -> NativeSegments.parse(payload, samples.size).also { cues = it.cues }.raw }) { WavInput.admit(samples, "This file is too short or silent. Use at least 0.4 seconds of speech."); samples }
        return TimedTranscript(text, samples.size, cues)
    }
    /** Recording preview: may be empty. [verify] once per session; the private model cannot change mid-recording without failing to load. */
    suspend fun draft(samples: FloatArray, model: File, catalog: SpeechModel, words: List<String>, language: String, verify: Boolean): String =
        recognize(model, catalog, words, language, {}, verify, draft = true) { samples }
    private suspend fun recognize(model: File, catalog: SpeechModel, words: List<String>, language: String, validate: () -> Unit,
                                  verify: Boolean = true, draft: Boolean = false, timing: TimingSession? = null,
                                  run: (Long, ByteArray, FloatArray, ByteArray, ByteArray) -> ByteArray? = native::recognize,
                                  raw: (ByteArray) -> ByteArray = { it }, load: () -> FloatArray): String = suspendCancellableCoroutine { c ->
        val revoked = AtomicBoolean(false)
        val token = native.createToken()
        c.invokeOnCancellation { revoked.set(true); native.cancel(token) }
        // Start outside the caller's cancellable job. Only actual native exit releases the token.
        nativeSubmit {
            try {
                if(revoked.get()) return@nativeSubmit
                validate()
                if(verify) { val begun = timing?.now(); ModelCatalog.verifyOnce(model, catalog); begun?.let { timing?.mark(TimingStage.model_verify, it) } }
                val samples = load()
                if(revoked.get()) return@nativeSubmit
                validate()
                // Durable marker before native code, cleared only by an actual native return.
                val mark = safeStart?.begin(catalog)
                val bytes = try {
                    run(token, model.absolutePath.toByteArray(Charsets.UTF_8), samples,
                        VocabularyHints.asrTerms(words).toByteArray(Charsets.UTF_8), SpeechLanguagePolicy.language(catalog,language).toByteArray(Charsets.UTF_8))
                } catch(t: Throwable) { ModelCatalog.forget(model); throw t } // a failed load re-verifies next time
                finally {
                    safeStart?.end(mark, resolve = !draft)
                    timing?.let { t -> native.lastTimings()?.takeIf { it.size == 2 }?.let { (load, decode) ->
                        if(load >= 0) t.duration(TimingStage.model_load, load)
                        if(decode >= 0) t.duration(TimingStage.whisper_decode, decode)
                    } }
                }
                val text = bytes?.takeIf { !revoked.get() }?.let(raw)?.toString(Charsets.UTF_8)?.let(TextRules::stripNonSpeech).orEmpty().trim()
                if(c.isActive && !revoked.get()) {
                    if(text.isEmpty() && !draft) c.resumeWithException(IllegalStateException("No speech recognized. Try a longer recording closer to the microphone.")) else c.resume(text)
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
/**
 * Phone dictation/import ceiling: 10 minutes, matching desktop. Kept equal across WavRecorder, this parser,
 * RecordingStore (via MAX_BYTES) and bridge.cpp's sample-count check (AudioLimitsTest asserts all of them).
 * Peak JVM heap at full length is about 58 MB: 19.2 MB WAV bytes plus 38.4 MB float samples while parsing.
 */
internal object WavInput {
    const val MAX_SECONDS = 600
    const val MAX_SAMPLES = 16000 * MAX_SECONDS
    const val MAX_DATA_BYTES = MAX_SAMPLES * 2
    const val MAX_BYTES = MAX_DATA_BYTES + 65536
    fun read(file: File, admitSpeech: Boolean = true): FloatArray {
        require(file.length() in 44L..MAX_BYTES.toLong()) { "Recording has an invalid size." }
        // readBytes allocates the file length once; readNBytes would buffer a second copy.
        return parse(file.readBytes(),admitSpeech)
    }
    /** [message] replaces both the too-short and the no-sound copy (file import uses its own). */
    fun admit(samples: FloatArray, message: String? = null) {
        require(samples.size <= MAX_SAMPLES) { "Recording is longer than ${MAX_SECONDS/60} minutes." }
        var squares = 0.0; for(sample in samples) squares += sample.toDouble()*sample
        val rms = if(samples.isEmpty()) 0.0 else sqrt(squares/samples.size)
        // 6400 samples = 0.4 s at 16 kHz, matching the Mac minimum. Keep the copy in step with this value.
        require(samples.size >= 6400) { message ?: "Recording is too short. Speak for at least 0.4 seconds." }
        require(rms >= 1e-4) { message ?: "No sound was picked up. Speak closer to the microphone and try again." }
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
                "data" -> { require(data == null && size % 2 == 0L && size <= MAX_DATA_BYTES) { "This recording contains invalid audio" }; data = start until end.toInt() }
            }
            i = (end + (size and 1)).toInt()
        }
        require(i == bytes.size && format && data != null) { "This recording is incomplete" }
        val range = data; val samples = FloatArray(range.count()/2) { index -> b.getShort(range.first+2*index)/32768f }
        require(samples.isNotEmpty()) { "Empty recording" }
        if(admitSpeech) admit(samples)
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
