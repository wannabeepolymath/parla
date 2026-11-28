package dev.parla.android

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class ImportedModelTest {
    /** base.en hparams in whisper_model_load order: vocab, audio ctx/state/head/layer, text ctx/state/head/layer, mels, ftype. */
    private fun header(vararg override: Pair<Int,Int>, magic: Int = 0x67676d6c): ByteArray {
        val h = intArrayOf(51864,1500,512,8,6,448,512,8,6,80,1).also { a -> override.forEach { (i,v) -> a[i] = v } }
        return ByteBuffer.allocate(ImportedModelFile.HEADER_BYTES).order(ByteOrder.LITTLE_ENDIAN).apply { putInt(magic); h.forEach(::putInt) }.array()
    }
    private fun modelBytes(size: Long = ImportedModelFile.MIN_BYTES) = header() + ByteArray((size-ImportedModelFile.HEADER_BYTES).toInt())

    @Test fun headerAcceptsWhisperHparamsAndRejectsEachMismatch() {
        assertTrue(ImportedModelFile.header(header()))
        assertTrue(ImportedModelFile.header(header(0 to 51866,2 to 1280,6 to 1280,3 to 20,7 to 20,4 to 32,8 to 4,9 to 128,10 to 2008))) // large-v3-turbo q5_0
        assertFalse(ImportedModelFile.header(header(magic = 0x67676a74))) // "ggjt" is a llama container
        assertFalse(ImportedModelFile.header(header().copyOf(47)))
        for(bad in listOf(0 to 32000,1 to 1499,2 to 500,3 to 0,4 to 5,5 to 512,6 to 768,7 to 9,8 to 0,9 to 40,10 to -1,10 to 28,10 to 3009))
            assertFalse("field ${bad.first}=${bad.second}",ImportedModelFile.header(header(bad)))
    }
    @Test fun copyChecksHeaderBeforeCopyingAndBoundsSize() {
        val dir = Files.createTempDirectory("parla-import").toFile()
        try {
            val part = File(dir,"part")
            var read = 0L
            val junk = object : java.io.InputStream() { override fun read() = 0.also { read++ } }
            assertEquals(ImportedModelFile.NOT_WHISPER,runCatching { ImportedModelFile.copy(junk,part,{ false }) }.exceptionOrNull()?.message)
            assertTrue("refused after the header, not after the file",read <= ImportedModelFile.HEADER_BYTES)
            assertTrue(runCatching { ImportedModelFile.copy(("<!DOCTYPE html>"+" ".repeat(64)).byteInputStream(),part,{ false }) }.exceptionOrNull()?.message.orEmpty().contains("web page"))
            assertTrue(runCatching { ImportedModelFile.copy(header().inputStream(),part,{ false }) }.exceptionOrNull()?.message.orEmpty().contains("too small"))
            assertTrue(runCatching { ImportedModelFile.copy((header()+ByteArray(200)).inputStream(),part,{ false },min = 48,max = 200) }.exceptionOrNull()?.message.orEmpty().contains("too large"))
            assertEquals(248L,ImportedModelFile.copy((header()+ByteArray(200)).inputStream(),part,{ false },min = 48,max = 248))
            assertTrue(runCatching { ImportedModelFile.copy((header()+ByteArray(200)).inputStream(),part,{ true },min = 48) }.isFailure)
        } finally { dir.deleteRecursively() }
    }
    @Test fun verifyChecksSizeAndHeaderWithoutAnyPin() {
        val dir = Files.createTempDirectory("parla-import").toFile()
        try {
            val f = File(dir,"m.bin").apply { writeBytes(modelBytes()) }
            val m = SpeechModel(SpeechModel.IMPORTED_ID,"Mine",f.length(),"",java.util.UUID.randomUUID().toString())
            ModelCatalog.verify(f,m)
            assertTrue(runCatching { ModelCatalog.verify(f,m.copy(bytes = m.bytes+1)) }.isFailure)
            f.writeBytes(ByteArray(f.length().toInt())) // same size, not a whisper file
            assertTrue(runCatching { ModelCatalog.verify(f,m) }.isFailure)
            File(dir,"tiny").writeBytes(header())
            assertTrue(runCatching { ModelCatalog.verify(File(dir,"tiny"),m.copy(bytes = 48)) }.isFailure)
        } finally { dir.deleteRecursively() }
    }
    @Test fun importGivesAnUnpinnedPrivateIdentityAndReplacesAtomically() = runBlocking {
        val root = Files.createTempDirectory("parla-import").toFile()
        try {
            val models = File(root,"speech-models"); val imports = File(root,"imports")
            val manager = ModelManager(models,ModelTransport { _,_,_ -> error("no network") },importDirectory = imports)
            assertNull(manager.selected(Settings(localModel = SpeechModel.IMPORTED_ID)))
            val first = manager.importModel("my\u0000 model.bin") { modelBytes().inputStream() }
            assertEquals("",first.sha256) // never a fabricated catalog pin
            assertTrue(first.imported && first.key == "imported:${first.importID}" && first.name == "my model.bin")
            assertEquals(first,manager.selected(Settings(localModel = SpeechModel.IMPORTED_ID)))
            ModelCatalog.verify(manager.file(first),first)
            assertTrue(runCatching { manager.importModel("bad") { ByteArray(ImportedModelFile.MIN_BYTES.toInt()).inputStream() } }.isFailure)
            assertEquals("a refused import keeps the earlier model",first,manager.imported.value)
            val second = manager.importModel("next") { modelBytes(ImportedModelFile.MIN_BYTES+2).inputStream() }
            assertNotEquals(first.key,second.key)
            assertFalse("replacement removes the earlier file",manager.file(first).exists())
            assertTrue(runCatching { ModelCatalog.verify(manager.file(first),first) }.isFailure)
            assertEquals(listOf("imported.json",second.filename),imports.list()!!.sorted())
            assertEquals("survives a restart",second,ModelManager(models,ModelTransport { _,_,_ -> error("no network") },importDirectory = imports).imported.value)
            manager.deleteImported()
            assertNull(manager.imported.value); assertEquals(emptyList<String>(),imports.list()!!.toList())
        } finally { root.deleteRecursively() }
    }
}
