package dev.parla.android

import java.io.ByteArrayOutputStream
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** P2-01: subtitle formatting/escaping, recognition JSON, and Kotlin-level validation of raw native segments. */
class SubtitleExportTest {
    private fun refusal(block: () -> Unit) = (runCatching(block).exceptionOrNull() as? SubtitleExport.Refused)?.refusal
    private fun payload(vararg segments: Triple<String, Long, Long>, raw: List<ByteArray>? = null, extra: ByteArray = ByteArray(0)): ByteArray {
        val out = ByteArrayOutputStream()
        fun put(value: Long, bytes: Int) = out.write(ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN).putLong(value).array(), 0, bytes)
        put(segments.size.toLong(), 4)
        segments.forEachIndexed { i, (text, start, end) ->
            val bytes = raw?.get(i) ?: text.toByteArray()
            put(start, 8); put(end, 8); put(bytes.size.toLong(), 4); out.write(bytes)
        }
        out.write(extra); return out.toByteArray()
    }

    @Test fun timestampsUseTenMillisecondTicks() {
        assertEquals("00:00:00.000", SubtitleExport.timestamp(0))
        assertEquals("00:20:34.560", SubtitleExport.timestamp(123_456))
        assertEquals("01:01:01,010", SubtitleExport.timestamp(366_101, ","))
        assertEquals("100:00:00.000", SubtitleExport.timestamp(36_000_000))
        assertEquals(SubtitleExport.Refusal.overflow, refusal { SubtitleExport.timestamp(-1) })
        assertEquals(SubtitleExport.Refusal.overflow, refusal { SubtitleExport.timestamp(Long.MAX_VALUE) })
    }

    @Test fun webVTTEscapesMarkupAndSrtRefusesIt() {
        val cues = listOf(Cue(" Tom & <Jerry>", 0, 150), Cue("Line one\r\nline two", 150, 300))
        assertEquals("WEBVTT\n\n1\n00:00:00.000 --> 00:00:01.500\n Tom &amp; &lt;Jerry&gt;\n\n2\n00:00:01.500 --> 00:00:03.000\nLine one\nline two\n\n",
            SubtitleExport.encode(cues, SubtitleExport.Format.webVTT))
        assertEquals("1\n00:00:01,500 --> 00:00:03,000\nLine one\nline two\n\n", SubtitleExport.encode(cues.drop(1).map { it.copy(start = 150, end = 300) }, SubtitleExport.Format.srt))
        for(text in listOf("<b>x</b>", "a {b}", "back\\slash", "fish &amp; chips")) assertEquals(text, SubtitleExport.Refusal.markup, refusal { SubtitleExport.encode(listOf(Cue(text, 0, 1)), SubtitleExport.Format.srt) })
        assertEquals("1\n00:00:00,000 --> 00:00:00,010\nfish & chips\n\n", SubtitleExport.encode(listOf(Cue("fish & chips", 0, 1)), SubtitleExport.Format.srt))
    }

    @Test fun unsafeOrEmptyPayloadIsRefusedBeforeMarkup() {
        for(text in listOf("", " ", "a\n\nb", "a\n \t", "bell\u0007", "nul\u0000", "c1\u0085", "line sep", "bidi‮override", "iso⁦late", "mark‏")) {
            assertEquals(text, SubtitleExport.Refusal.payload, refusal { SubtitleExport.encode(listOf(Cue(text, 0, 1)), SubtitleExport.Format.webVTT) })
        }
        assertEquals("1\n00:00:00.000 --> 00:00:00.010\n\ttab\n\n", SubtitleExport.encode(listOf(Cue("\ttab", 0, 1)), SubtitleExport.Format.webVTT).removePrefix("WEBVTT\n\n"))
        assertEquals(SubtitleExport.Refusal.payload, refusal { SubtitleExport.encode(listOf(Cue("<b>", 0, 1), Cue("bad\u0001", 1, 2)), SubtitleExport.Format.srt) })
        assertEquals(SubtitleExport.Refusal.empty, refusal { SubtitleExport.encode(emptyList(), SubtitleExport.Format.webVTT) })
        assertEquals(SubtitleExport.Refusal.overflow, refusal { SubtitleExport.encode(listOf(Cue("late", 0, 36_000_000)), SubtitleExport.Format.srt) })
        SubtitleExport.encode(listOf(Cue("late", 0, 36_000_000)), SubtitleExport.Format.webVTT)
        assertEquals(SubtitleExport.Refusal.limit, refusal { SubtitleExport.encode(listOf(Cue("x".repeat(100), 0, 1)), SubtitleExport.Format.webVTT, maximumBytes = 100) })
        assertEquals(SubtitleExport.Refusal.limit, refusal { SubtitleExport.encode(listOf(Cue("&", 0, 1)), SubtitleExport.Format.webVTT, maximumBytes = 46) })
        assertEquals(47, SubtitleExport.encode(listOf(Cue("&", 0, 1)), SubtitleExport.Format.webVTT, maximumBytes = 47).length)
    }

    @Test fun recognitionJsonHasSortedKeysExplicitNullsAndNoSynthesizedTiming() {
        val model = ModelCatalog.all.first()
        val untimed = RecognitionExport.encode(TimedTranscript("a/b \"q\"\n", 8000, null), model, null)
        assertEquals("""{"cleanedText":null,"engine":"whisper","language":{"detected":null,"requested":null},"model":{"expectedSHA256":"${model.sha256}","id":"base.en","kind":"catalog"},"rawText":"a/b \"q\"\n","runtime":null,"schema":"parla.recognition.v1","segments":null,"source":{"sampleCount":8000,"sampleRate":16000},"words":null}""", untimed)
        val timed = JSONObject(RecognitionExport.encode(TimedTranscript("hi", 16000, listOf(Cue(" hi", 0, 100))), model, "en"))
        assertEquals("whisper-1.9.1-pcm-10ms", timed.getJSONObject("segments").getString("clock"))
        assertEquals(" hi", timed.getJSONObject("segments").getJSONArray("cues").getJSONObject(0).getString("text"))
        assertEquals("en", timed.getJSONObject("language").getString("requested"))
        assertEquals("parla-recognition-1970-01-01.json", RecognitionExport.filename(0))
    }

    @Test fun nativeSegmentsAreValidatedAndATimingRefusalKeepsTheRawText() {
        val ok = NativeSegments.parse(payload(Triple(" Hello", 0, 100), Triple(" world", 100, 200)), 32_000)
        assertEquals(" Hello world", ok.raw.toString(Charsets.UTF_8))
        assertEquals(listOf(Cue(" Hello", 0, 100), Cue(" world", 100, 200)), ok.cues)
        // Each Mac RecognitionSegments refusal drops only the timing.
        val refused = listOf(
            payload(Triple("a", 10, 10)),                      // end must be after start
            payload(Triple("a", -1, 5)),                       // negative start
            payload(Triple("a", 0, 201)),                      // beyond the source (201 * 160 > 32000)
            payload(Triple("a", 50, 60), Triple("b", 40, 70)), // starts never decrease
        )
        for(p in refused) { val parsed = NativeSegments.parse(p, 32_000); assertNull(parsed.cues); assertTrue(parsed.raw.isNotEmpty()) }
        assertEquals(listOf(Cue("a", 0, 200)), NativeSegments.parse(payload(Triple("a", 0, 200)), 32_000).cues) // exactly at the end
        assertNull(NativeSegments.parse(payload(Triple("x", 0, 1), raw = listOf(byteArrayOf(0xC3.toByte()))), 32_000).cues) // malformed UTF-8
        assertNull(NativeSegments.parse(payload(Triple("x", 0, 1)), 0).cues)
        // Structural damage or bounds the bridge must enforce are failures, not partial output.
        assertTrue(runCatching { NativeSegments.parse(payload(Triple("a", 0, 1), extra = byteArrayOf(1)), 32_000) }.isFailure)
        assertTrue(runCatching { NativeSegments.parse(payload(Triple("a", 0, 1)).dropLast(1).toByteArray(), 32_000) }.isFailure)
        assertTrue(runCatching { NativeSegments.parse(ByteBuffer.allocate(4).order(ByteOrder.LITTLE_ENDIAN).putInt(NativeSegments.MAX_COUNT + 1).array(), 32_000) }.isFailure)
        assertTrue(runCatching { NativeSegments.parse(payload(Triple("x".repeat(NativeSegments.MAX_BYTES + 1), 0, 1)), 32_000) }.isFailure)
        NativeSegments.parse(payload(Triple("x".repeat(NativeSegments.MAX_BYTES), 0, 1)), 32_000)
    }

    @Test fun timedTranscriptionUsesTheTimedNativeCallAndTheSameAdmission() = runBlocking {
        val dir = Files.createTempDirectory("parla-timed").toFile()
        try {
            val bytes = "fake model".toByteArray()
            val m = SpeechModel("fake", "Fake", bytes.size.toLong(), SavedImportStore.digest(bytes))
            val model = File(dir, "model").apply { writeBytes(bytes) }
            var timedCalls = 0
            val native = object : SpeechNative {
                override fun createToken() = 1L
                override fun cancel(token: Long) {}
                override fun release(token: Long) {}
                override fun recognize(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray = error("untimed path")
                override fun recognizeTimed(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray {
                    timedCalls++; return payload(Triple(" [BLANK_AUDIO]", 0, 10), Triple(" Hello.", 10, 50))
                }
            }
            val result = LocalSpeech(native).transcribeTimed(FloatArray(8000) { 0.1f }, model, m, emptyList(), "en")
            assertEquals("Hello.", result.text) // the text path still strips non-speech markers
            assertEquals(listOf(Cue(" [BLANK_AUDIO]", 0, 10), Cue(" Hello.", 10, 50)), result.cues) // cues stay literal
            assertEquals(8000, result.sampleCount); assertEquals(1, timedCalls)
            assertTrue(runCatching { LocalSpeech(native).transcribeTimed(FloatArray(6399) { 0.1f }, model, m, emptyList(), "en") }.isFailure)
            assertEquals(1, timedCalls)
        } finally { dir.deleteRecursively() }
    }
}
