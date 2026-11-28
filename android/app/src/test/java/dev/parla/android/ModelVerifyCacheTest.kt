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
            var fail = false; var prepared = true
            val native = object : SpeechNative {
                override fun createToken() = 1L
                override fun cancel(token: Long) {}
                override fun release(token: Long) {}
                override fun recognize(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray =
                    if(fail) throw IllegalStateException("Model could not be loaded.") else "hello".toByteArray()
                override fun lastTimings() = if(fail) longArrayOf(7, -1, 1) else longArrayOf(12, 34, 0) // init returned null
                override fun prepare(model: ByteArray) = prepared
            }
            val events = mutableListOf<TimingEvent>()
            fun run() = runCatching { runBlocking { LocalSpeech(native, null).transcribe(FloatArray(8000) { 0.1f }, f, m, emptyList(), "en", timing = TimingSession(sink = { events += it })) } }
            fun log() = events.map { "${it.stage} ${it.durationMs} ${it.outcome}" }.also { events.clear() }
            assertEquals("hello", run().getOrThrow())
            assertEquals(listOf("model_verify", "model_load 12 ok", "whisper_decode 34 ok"), log().map { it.replace(Regex("^model_verify .*"), "model_verify") })
            fail = true
            assertTrue(run().isFailure)
            assertEquals(listOf("model_load 7 failed"), log().drop(1))
            tamper(f) // the failed load forgot the trust record: the next verify hashes and refuses
            assertTrue(run().isFailure)
            assertEquals(listOf(TimingOutcome.failed), log().map { TimingOutcome.valueOf(it.substringAfterLast(' ')) })

            // Safe Start's explicit load: a refused prepare forgets trust too.
            f.writeBytes(bytes); f.setLastModified(4_000_000); ModelCatalog.verifyOnce(f, m)
            val safe = SafeStart(DurableFile(File(dir, "safe-start.json")))
            prepared = false
            assertFalse(safe.tryOnce(m, f, native))
            tamper(f)
            assertTrue(runCatching { ModelCatalog.verifyOnce(f, m) }.isFailure)
        } finally { ModelCatalog.forget(); dir.deleteRecursively() }
    }
}
