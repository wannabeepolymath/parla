package dev.parla.android

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ModelVerifyCacheTest {
    private fun model(bytes: ByteArray) = SpeechModel("fake", "Fake", bytes.size.toLong(), MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
    /** Same length and mtime, different bytes: only a full hash can tell. */
    private fun tamper(f: File) { val t = f.lastModified(); f.writeBytes(ByteArray(f.length().toInt()) { 7 }); f.setLastModified(t) }

    @Test fun verifiedOnceIsTrustedUntilLengthMtimeOrIdentityChangesOrItIsForgotten() {
        val dir = Files.createTempDirectory("parla-verify").toFile()
        try {
            val bytes = "real model bytes".toByteArray(); val m = model(bytes)
            val f = File(dir, "ggml-fake.bin").apply { writeBytes(bytes); setLastModified(1_000_000) }
            ModelCatalog.verifyOnce(f, m)
            tamper(f)
            ModelCatalog.verifyOnce(f, m) // trusted: no rehash
            assertTrue(runCatching { ModelCatalog.verifyOnce(f, m.copy(sha256 = "0".repeat(64))) }.isFailure) // other identity
            f.setLastModified(2_000_000)
            assertTrue(runCatching { ModelCatalog.verifyOnce(f, m) }.isFailure)
            f.writeBytes(bytes); f.setLastModified(3_000_000); ModelCatalog.verifyOnce(f, m)
            ModelCatalog.forget(); tamper(f)
            assertTrue(runCatching { ModelCatalog.verifyOnce(f, m) }.isFailure)
        } finally { ModelCatalog.forget(); dir.deleteRecursively() }
    }

    @Test fun recognitionRecordsStageTimingsAndAFailedLoadReverifies() = runBlocking {
        val dir = Files.createTempDirectory("parla-verify").toFile()
        try {
            val bytes = "real model bytes".toByteArray(); val m = model(bytes)
            val f = File(dir, "ggml-fake.bin").apply { writeBytes(bytes); setLastModified(1_000_000) }
            var fail = false
            val native = object : SpeechNative {
                override fun createToken() = 1L
                override fun cancel(token: Long) {}
                override fun release(token: Long) {}
                override fun recognize(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray =
                    if(fail) throw IllegalStateException("Model could not be loaded.") else "hello".toByteArray()
                override fun lastTimings() = longArrayOf(12, 34)
            }
            val events = mutableListOf<TimingEvent>()
            assertEquals("hello", LocalSpeech(native, null).transcribe(FloatArray(8000) { 0.1f }, f, m, emptyList(), "en", timing = TimingSession(sink = { events += it })))
            assertEquals(listOf(TimingStage.model_verify, TimingStage.model_load, TimingStage.whisper_decode), events.map { it.stage })
            assertEquals(listOf(12L, 34L), events.drop(1).map { it.durationMs })
            fail = true
            assertTrue(runCatching { LocalSpeech(native, null).transcribe(FloatArray(8000) { 0.1f }, f, m, emptyList(), "en") }.isFailure)
            tamper(f)
            assertTrue(runCatching { ModelCatalog.verifyOnce(f, m) }.isFailure)
        } finally { ModelCatalog.forget(); dir.deleteRecursively() }
    }
}
