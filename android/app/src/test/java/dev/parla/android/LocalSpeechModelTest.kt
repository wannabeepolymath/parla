package dev.parla.android

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.security.MessageDigest
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class LocalSpeechModelTest {
    private fun wav(count: Int = 8000, sample: Short = 4000): ByteArray = WavHeader.create(count*2L) + ByteBuffer.allocate(count*2).order(ByteOrder.LITTLE_ENDIAN).apply { repeat(count) { putShort(sample) } }.array()
    private fun model(bytes: ByteArray) = SpeechModel("fake","Fake",bytes.size.toLong(),MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
    @Test fun wavAdmissionUsesSignedPcmAndBoundedValidatedContainer() {
        assertEquals(-1f,WavInput.parse(wav(sample = Short.MIN_VALUE))[0],0f)
        assertEquals(32767/32768f,WavInput.parse(wav(sample = Short.MAX_VALUE))[0],0f)
        for(bytes in listOf(wav(6399),wav(sample = 0),wav().copyOf(50),wav().also { it[22] = 2 },wav().also { it[40] = 1 },wav().also { it[24] = 1 })) assertTrue(runCatching { WavInput.parse(bytes) }.isFailure)
        assertEquals("",TextRules.stripNonSpeech("[BLANK_AUDIO] (upbeat music) *sigh*"))
        assertEquals("Hello.",TextRules.stripNonSpeech("Hello.\n[BLANK_AUDIO]"))
        assertEquals("Hello (a) [0] (upbeat music)",TextRules.stripNonSpeech("Hello (a) [0] (upbeat music)"))
    }
    @Test fun catalogLanguagePolicyForcesEnglishAndPreservesMultilingualAutoOrPinned() {
        for(model in ModelCatalog.all.take(2)) {
            assertEquals("en",SpeechLanguagePolicy.language(model,"hi"))
            assertEquals("en",SpeechLanguagePolicy.language(model,"auto"))
        }
        val multi = ModelCatalog.all.last()
        assertEquals("hi",SpeechLanguagePolicy.language(multi,"hi"))
        assertEquals("auto",SpeechLanguagePolicy.language(multi,"auto"))
        assertEquals("auto",SpeechLanguagePolicy.language(multi,"invalid"))
    }
    @Test fun productionModelTransferRejectsPartialMarkupHashAndPreservesInstalledBytes() {
        val dir = Files.createTempDirectory("parla-model-test").toFile()
        try {
            val bytes = "model-test".toByteArray(); val m = model(bytes); val part = File(dir,"model.part"); val dest = File(dir,"model.bin").apply { writeText("last usable") }
            assertTrue(runCatching { ModelCatalog.copyDownload("short".byteInputStream(),part,m,{ false },{}) }.isFailure)
            assertEquals("last usable",dest.readText())
            ModelCatalog.copyDownload(bytes.inputStream(),part,m,{ false },{})
            assertTrue(runCatching { ModelCatalog.install(part,dest,m.copy(sha256 = "bad")) }.isFailure); assertEquals("last usable",dest.readText())
            assertTrue(runCatching { ModelCatalog.install(part,dest,m) { false } }.isFailure)
            assertEquals("last usable",dest.readText())
            ModelCatalog.install(part,dest,m); assertArrayEquals(bytes,dest.readBytes()); assertFalse(part.exists())
            part.writeBytes(bytes)
            assertTrue(runCatching { ModelCatalog.copyDownload(bytes.inputStream(),part,m,{ true },{}) }.isFailure)
            assertArrayEquals(bytes,dest.readBytes())
            part.writeText("<html>bad!")
            assertTrue(runCatching { ModelCatalog.verify(part,model(part.readBytes())) }.isFailure)
            assertTrue(runCatching { ModelCatalog.copyDownload((bytes+1.toByte()).inputStream(),part,m,{ false },{}) }.isFailure)
            assertEquals(listOf(147964211L,190098681L,574041195L),ModelCatalog.all.map { it.bytes })
            assertTrue(ModelCatalog.all.all { it.sha256.length == 64 })
        } finally { dir.deleteRecursively() }
    }
    @Test fun cancellationSignalsImmediatelyButNativeExitOwnsResourcesAndBlocksNextCall() = runBlocking {
        val dir = Files.createTempDirectory("parla-native-test").toFile()
        val entered = CountDownLatch(1); val exit = CountDownLatch(1); val released = CountDownLatch(1)
        val canceled = AtomicBoolean(false); val secondStarted = AtomicBoolean(false)
        val bytes = "fake model".toByteArray(); val m = model(bytes)
        val model = File(dir,"fake.bin").apply { writeBytes(bytes) }; val wav = File(dir,"audio.wav").apply { writeBytes(wav()) }
        val fake = object : SpeechNative {
            override fun createToken() = 123L
            override fun cancel(token: Long) { assertEquals(123L,token); canceled.set(true) }
            override fun release(token: Long) { released.countDown() }
            override fun recognize(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray {
                assertEquals("hi",language.toString(Charsets.UTF_8)); assertEquals("👋 नमस्ते",prompt.toString(Charsets.UTF_8))
                entered.countDown(); check(exit.await(5,TimeUnit.SECONDS)); return "late text".toByteArray()
            }
        }
        try {
            var published = false
            val job = launch(Dispatchers.Default) { LocalSpeech(fake).transcribe(wav,model,m,listOf("👋 नमस्ते"),"hi"); published = true }
            assertTrue(withContext(Dispatchers.IO) { entered.await(5,TimeUnit.SECONDS) })
            job.cancelAndJoin(); assertTrue(canceled.get()); assertEquals(1L,released.count)
            val next = async(Dispatchers.Default) { NativeTasks.run { secondStarted.set(true) } }
            assertFalse(secondStarted.get()); exit.countDown(); next.await()
            assertTrue(released.await(5,TimeUnit.SECONDS)); assertFalse(published)
            assertTrue(secondStarted.get())
        } finally { exit.countDown(); released.await(5,TimeUnit.SECONDS); dir.deleteRecursively() }
    }
    @Test fun successfulNativeSeamDeliversUnicodeAndStripsMarkersWithoutProvider() = runBlocking {
        val dir = Files.createTempDirectory("parla-unicode-test").toFile()
        try {
            val b = "fake model".toByteArray(); val m = model(b)
            val model = File(dir,"model").apply { writeBytes(b) }; val audio = File(dir,"audio").apply { writeBytes(wav()) }
            var released = false
            val fake = object : SpeechNative {
                override fun createToken() = 1L
                override fun cancel(token: Long) { error("unexpected cancellation") }
                override fun release(token: Long) { released = true }
                override fun recognize(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray) = " 👋 नमस्ते [BLANK_AUDIO] ".toByteArray(Charsets.UTF_8)
            }
            assertEquals("👋 नमस्ते",LocalSpeech(fake).transcribe(audio,model,m,emptyList(),"auto"))
            NativeTasks.run { assertTrue(released) }
        } finally { dir.deleteRecursively() }
    }
}
