package dev.parla.android

import java.io.File
import java.io.FileOutputStream
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import org.junit.Assert.*
import org.junit.Test

class DurableFileTest {
    @Test fun productionAdapterRejectsSyncAndRenameFailuresWithoutPublishingState() {
        val root = Files.createTempDirectory("parla-durable-test").toFile().canonicalFile
        try {
            val base = File(root,"parla-data.json"); var closeBeforeSync = false
            val file = DurableFile(base) { target ->
                object : FileOutputStream(target) {
                    override fun write(bytes: ByteArray) { super.write(bytes); if(closeBeforeSync) close() }
                }
            }
            val state = LocalState(FileStateStorage(file))
            assertTrue(state.update { it.copy(dictionary = listOf("saved")) })
            val saved = base.readBytes()
            closeBeforeSync = true // The actual FileDescriptor.sync now throws, rather than a Memory fake.
            assertFalse(state.update { it.copy(dictionary = listOf("unsaved")) })
            assertEquals(listOf("saved"),state.data.value.dictionary); assertArrayEquals(saved,base.readBytes())
            assertFalse(state.repair(LocalDataCodec.encode(LocalData(dictionary = listOf("failed repair")))))
            assertEquals(listOf("saved"),state.data.value.dictionary); assertArrayEquals(saved,base.readBytes())
            assertNotNull(state.error.value); assertFalse(File(root,"parla-data.json.new").exists())
            assertTrue(runCatching { file.write("ciphertext".toByteArray()) }.isFailure) // Same adapter used for provider keys.
            closeBeforeSync = false
            assertTrue(base.delete()); assertTrue(base.mkdir()); File(base,"block-rename").writeText("preserve")
            assertFalse(state.update { it.copy(dictionary = listOf("unpublished")) })
            assertEquals(listOf("saved"),state.data.value.dictionary); assertTrue(File(base,"block-rename").exists())
            assertTrue(runCatching { file.write("ciphertext".toByteArray()) }.isFailure)
            assertTrue(base.deleteRecursively())
            File(root,"parla-data.json.bak").writeBytes(saved)
            File(root,"parla-data.json.new").writeText("interrupted")
            assertArrayEquals(saved,file.read()); assertFalse(File(root,"parla-data.json.new").exists())
            assertFalse(File(root,"parla-data.json.bak").exists())
            assertTrue(state.reload()); assertTrue(state.update { it.copy(dictionary = listOf("retried")) })
            assertEquals(listOf("retried"),LocalState(FileStateStorage(file)).data.value.dictionary)
        } finally { root.deleteRecursively() }
    }
    @Test fun originalReadsWaitForTheStateWriteLockWithoutDeletingPendingBytes() {
        val root = Files.createTempDirectory("parla-original-test").toFile().canonicalFile
        val reader = Executors.newSingleThreadExecutor()
        try {
            val base = File(root,"parla-data.json")
            val state = LocalState(FileStateStorage(DurableFile(base)))
            assertTrue(state.update { it })
            val pending = File(root,"parla-data.json.new"); val attempted = CountDownLatch(1)
            val result = synchronized(state) {
                pending.writeText("in-progress write")
                val future = reader.submit<String> { attempted.countDown(); state.original() }
                assertTrue(attempted.await(2,TimeUnit.SECONDS))
                try { future.get(200,TimeUnit.MILLISECONDS); fail("Original read bypassed write lock") }
                catch(_: TimeoutException) { /* The reader must wait until the write lock is released. */ }
                assertTrue(pending.exists()); future
            }
            assertEquals(base.readText(),result.get(2,TimeUnit.SECONDS))
        } finally { reader.shutdownNow(); reader.awaitTermination(2,TimeUnit.SECONDS); root.deleteRecursively() }
    }
}
