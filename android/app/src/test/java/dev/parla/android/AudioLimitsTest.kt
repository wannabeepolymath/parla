package dev.parla.android

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class AudioLimitsTest {
    private fun wav(samples: Int): ByteArray = WavHeader.create(samples * 2L) +
        ByteBuffer.allocate(samples * 2).order(ByteOrder.LITTLE_ENDIAN).apply { repeat(samples) { putShort(if(it % 2 == 0) 3000 else -3000) } }.array()

    @Test fun tenMinuteCeilingIsTheSameInEveryLayer() {
        assertEquals(600, WavInput.MAX_SECONDS)
        assertEquals(WavInput.MAX_SECONDS, WavRecorder.MAX_SECONDS)
        assertEquals(WavInput.MAX_DATA_BYTES.toLong(), WavRecorder.MAX_DATA_BYTES)
        assertEquals(16_000 * 600, WavInput.MAX_SAMPLES)
        assertTrue(WavInput.MAX_BYTES >= 44 + WavInput.MAX_DATA_BYTES)
        // RecordingStore admits and parses through WavInput.MAX_BYTES; the JNI bridge has its own literal.
        val bridge = File("../native/bridge.cpp").readText()
        val ceiling = Regex("""count > 16000 \* (\d+)""").find(bridge)!!.groupValues[1].toInt()
        assertEquals(WavInput.MAX_SECONDS, ceiling)
        // Mic test and file import stay within the dictation ceiling.
        assertTrue(MicTestPolicy.MAX_SAMPLES <= WavInput.MAX_SAMPLES)
    }

    @Test fun fullLengthRecordingIsAcceptedAndOneSampleMoreIsRefused() {
        val file = Files.createTempFile("parla-limit", ".wav").toFile()
        try {
            file.writeBytes(wav(WavInput.MAX_SAMPLES))
            assertEquals(WavInput.MAX_SAMPLES, WavInput.read(file).size)
            file.writeBytes(wav(WavInput.MAX_SAMPLES + 1))
            assertTrue(runCatching { WavInput.read(file) }.isFailure)
        } finally { file.delete() }
        assertTrue(runCatching { WavInput.admit(FloatArray(WavInput.MAX_SAMPLES + 1) { 0.1f }) }.isFailure)
        WavInput.admit(FloatArray(WavInput.MAX_SAMPLES) { 0.1f })
    }

    @Test fun decodedSamplesUseTheSameAdmissionAndNativeSeamAsRecordings() = runBlocking {
        val dir = Files.createTempDirectory("parla-import-test").toFile()
        try {
            val bytes = "fake model".toByteArray()
            val m = SpeechModel("fake", "Fake", bytes.size.toLong(), java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
            val model = File(dir, "model").apply { writeBytes(bytes) }
            var received = 0
            val native = object : SpeechNative {
                override fun createToken() = 1L
                override fun cancel(token: Long) {}
                override fun release(token: Long) {}
                override fun recognize(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray { received = samples.size; return "imported".toByteArray() }
            }
            val short = runCatching { LocalSpeech(native).transcribe(FloatArray(6399) { 0.1f }, model, m, emptyList(), "auto") }.exceptionOrNull()?.message.orEmpty()
            assertTrue(short.contains("too short or silent")); assertEquals(0, received)
            assertTrue(runCatching { LocalSpeech(native).transcribe(FloatArray(8000), model, m, emptyList(), "auto") }.isFailure); assertEquals(0, received)
            assertEquals("imported", LocalSpeech(native).transcribe(FloatArray(8000) { 0.1f }, model, m, emptyList(), "auto"))
            assertEquals(8000, received)
        } finally { dir.deleteRecursively() }
    }

    @Test fun microphoneTestStatusPrefersSilencingOverQuietAudio() {
        assertEquals(MicTestPolicy.State.silenced, MicTestPolicy.capture(16_000, false, true, 3_000, false))
        assertEquals(MicTestPolicy.State.silent, MicTestPolicy.capture(16_000, false, false, 3_000, false))
        assertEquals(MicTestPolicy.State.signal, MicTestPolicy.capture(16_000, true, false, 3_000, true))
        assertEquals(MicTestPolicy.State.starting, MicTestPolicy.capture(0, false, false, 1_000, false))
        assertEquals(MicTestPolicy.State.stoppedBeforeAudio, MicTestPolicy.capture(0, false, false, 1_000, true))
        assertEquals(MicTestPolicy.State.noAudio, MicTestPolicy.capture(0, false, false, 2_000, true))
        assertEquals(160_000, MicTestPolicy.MAX_SAMPLES)
        assertEquals(MicTestPolicy.MAX_RUN_MS, MicTestPolicy.MAX_SAMPLES * 1000L / MicTestPolicy.SAMPLE_RATE)
    }
}
