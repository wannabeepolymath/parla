package dev.parla.android

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.Assert.*
import org.junit.Test

class RecognitionPreviewTest {
    private val capable = PreviewPolicy.Device(lowRam = false,totalMemory = 8_000_000_000L,cores = 8)

    @Test fun previewIsOffByDefaultAndPersistsOnlyAnExplicitChoice() {
        assertFalse(Settings().previewEnabled)
        assertFalse(PreviewPolicy.active(Settings(),capable,modelInstalled = true))
        val on = LocalData(Settings(previewEnabled = true))
        assertTrue(LocalDataCodec.decode(LocalDataCodec.encode(on)).settings.previewEnabled)
        val legacy = org.json.JSONObject(LocalDataCodec.encode(LocalData(Settings(previewEnabled = true)))).also { it.getJSONObject("settings").remove("previewEnabled") }.toString()
        assertFalse(legacy.contains("previewEnabled")); assertFalse(LocalDataCodec.decode(legacy).settings.previewEnabled)
        assertTrue(runCatching { LocalDataCodec.decode(LocalDataCodec.encode(on).replace("\"previewEnabled\":true","\"previewEnabled\":\"true\"" /* org.json's getBoolean would coerce this */)) }.isFailure)
    }
    @Test fun gatingRefusesDevicesAndSettingsThatCannotSustainIt() {
        val s = Settings(previewEnabled = true)
        assertTrue(PreviewPolicy.active(s,capable,true))
        assertTrue(PreviewPolicy.active(s.copy(language = "en"),capable,true))
        for(d in listOf(capable.copy(lowRam = true),capable.copy(totalMemory = PreviewPolicy.MIN_MEMORY_BYTES-1),capable.copy(cores = PreviewPolicy.MIN_CORES-1))) {
            assertNotNull(PreviewPolicy.unsupported(d)); assertFalse(PreviewPolicy.active(s,d,true))
        }
        assertNull(PreviewPolicy.unsupported(capable.copy(totalMemory = PreviewPolicy.MIN_MEMORY_BYTES,cores = PreviewPolicy.MIN_CORES)))
        assertFalse("needs the small draft model downloaded",PreviewPolicy.active(s,capable,false))
        assertFalse("the draft model is English only",PreviewPolicy.active(s.copy(language = "hi"),capable,true))
        assertEquals("base.en",PreviewPolicy.model.id)
    }
    @Test fun draftsComeFromTheRecordingTailAndStopOnAModelFailure() = runBlocking {
        val dir = Files.createTempDirectory("parla-preview").toFile()
        try {
            val bytes = "model".toByteArray()
            val m = SpeechModel("fake","Fake",bytes.size.toLong(),java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
            val modelFile = File(dir,"model.bin").apply { writeBytes(bytes) }
            // A recording still being written: header with a zero data size, then PCM.
            val wav = File(dir,"rec.wav").apply { writeBytes(WavHeader.create(0)+ByteBuffer.allocate(2*20000).order(ByteOrder.LITTLE_ENDIAN).apply { repeat(20000) { putShort(16384) } }.array()) }
            assertEquals(20000,RecognitionPreview.tail(wav).size); assertEquals(.5f,RecognitionPreview.tail(wav)[0],0f)
            val seen = mutableListOf<Int>(); var calls = 0
            val native = object : SpeechNative {
                override fun createToken() = 1L
                override fun cancel(token: Long) {}
                override fun release(token: Long) {}
                override fun recognize(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray? {
                    calls++; seen += samples.size
                    assertEquals("en",language.toString(Charsets.UTF_8))
                    return if(calls < 3) "draft $calls".toByteArray() else throw IllegalStateException("Model could not be loaded")
                }
            }
            val drafts = mutableListOf<String>()
            withTimeout(5000) { RecognitionPreview(LocalSpeech(native,null),intervalMs = 1).run(wav,modelFile,m,emptyList()) { drafts += it } }
            assertEquals(listOf("draft 1","draft 2"),drafts)
            assertEquals(listOf(20000,20000,20000),seen)
        } finally { dir.deleteRecursively() }
    }
}
