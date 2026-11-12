package dev.parla.android

import java.io.File
import java.nio.file.Files
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import kotlinx.coroutines.flow.first
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class ModelTransferTest {
    private val bytes = "synthetic-model!".toByteArray()
    private val model = SpeechModel("synthetic","Synthetic",bytes.size.toLong(),MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
    private fun dir() = Files.createTempDirectory("parla-transfer-test").toFile().canonicalFile
    private fun partial(request: TransferRequest, chunk: File, tag: String = "\"revision1\""): TransferResponse {
        chunk.writeBytes(bytes.copyOfRange(request.start.toInt(),request.end.toInt()+1))
        return TransferResponse(206,mapOf("Content-Range" to "bytes ${request.start}-${request.end}/${model.bytes}","ETag" to tag))
    }
    @Test fun recoversPassivelyAndResumesWithPinnedRangeValidatorWithoutSelecting() = runTest {
        val root = dir(); val requests = mutableListOf<TransferRequest>()
        try {
            val first = ModelManager(root,ModelTransport { r,f,_ -> requests += r; if(r.start > 0) throw CancellationException(); partial(r,f) },StandardTestDispatcher(testScheduler),listOf(model),4)
            first.download(model); first.waitForExit()
            assertEquals(4L,first.storage.read(model)!!.offset)
            val resumed = ModelManager(root,ModelTransport { r,f,_ -> requests += r; partial(r,f) },StandardTestDispatcher(testScheduler),listOf(model),4)
            assertTrue(resumed.rows.value[model.id]!!.paused); assertEquals(2,requests.size)
            assertFalse(resumed.file(model).exists())
            resumed.download(model); resumed.waitForExit()
            assertEquals(4L,requests[2].start); assertEquals("\"revision1\"",requests[2].validator)
            assertArrayEquals(bytes,resumed.file(model).readBytes()); assertNull(resumed.storage.read(model))
            assertTrue(resumed.transfer.value.message.contains("Tap Select"))
        } finally { root.deleteRecursively() }
    }
    @Test fun interruptedDiscardWithMissingPartialAllowsFreshDownloads() = runTest {
        val root = dir(); val other = model.copy(id = "other")
        try {
            val storage = TransferStorage(root,listOf(model,other))
            val legacy = { // Old discard died after deleting the partial but before its journal.
                val c = storage.prepare(model,UUID.randomUUID().toString(),TransferPermit())
                storage.files.atomic(storage.journal(model),c.copy(offset = 4,validator = TransferValidator("etag","\"revision1\"")).encode())
                storage.files.remove(storage.files.file(c.stage)); c
            }
            val checkpoint = legacy()
            assertTrue(runCatching { storage.read(model) }.isFailure)
            val m = ModelManager(root,ModelTransport { q,f,_ -> partial(q,f) },StandardTestDispatcher(testScheduler),listOf(model,other),4)
            m.discard(model); assertNull(storage.read(model))
            legacy() // Without an explicit Discard, other downloads and Resume/Download of the same model still proceed.
            m.download(other); m.waitForExit(); assertArrayEquals(bytes,m.file(other).readBytes())
            m.download(model); m.waitForExit(); assertArrayEquals(bytes,m.file(model).readBytes())
            // A new interrupted discard leaves only an orphan, which explicit scratch cleanup removes.
            val orphaned = storage.prepare(model,UUID.randomUUID().toString(),TransferPermit())
            storage.fault = { if(it == "discard") error("Interrupted discard") }
            assertTrue(runCatching { storage.discard(model) }.isFailure)
            assertFalse(storage.journal(model).exists()); assertTrue(File(root,orphaned.stage).exists())
            storage.fault = {}
            m.download(other); m.waitForExit(); assertFalse(File(root,orphaned.stage).exists())
            // Unknown provenance is deliberately preserved, even during explicit Discard.
            val unknown = checkpoint.copy(hash = "0".repeat(64))
            storage.files.atomic(storage.journal(model),unknown.encode())
            assertTrue(runCatching { storage.discard(model) }.isFailure)
            assertTrue(storage.journal(model).exists())
        } finally { root.deleteRecursively() }
    }
    @Test fun cancellationBeforeDispatchSettlesAndNeverCallsTransport() = runTest {
        val root = dir(); var calls = 0
        try {
            val m = ModelManager(root,ModelTransport { _,_,_ -> calls++; error("unreachable") },StandardTestDispatcher(testScheduler),listOf(model),4)
            m.download(model); m.pause(); m.waitForExit()
            assertEquals(0,calls); assertFalse(m.transfer.value.active)
            m.download(model); m.waitForExit(); assertEquals(1,calls)
        } finally { root.deleteRecursively() }
    }
    @Test fun discardAndNewGenerationWaitForActualWriterExit() = runBlocking {
        val root = dir(); val entered = CountDownLatch(1); val exit = CountDownLatch(1); val calls = AtomicInteger()
        try {
            val m = ModelManager(root,ModelTransport { r,f,p -> calls.incrementAndGet(); entered.countDown(); check(exit.await(5,TimeUnit.SECONDS)); f.writeBytes(bytes); p.check(); partial(r,f) },Dispatchers.IO,listOf(model),4)
            m.download(model); assertTrue(withContext(Dispatchers.IO) { entered.await(5,TimeUnit.SECONDS) })
            val stage = m.storage.read(model)!!.stage
            m.discard(model); m.download(model)
            assertTrue(File(root,stage).exists()); assertEquals(1,calls.get()); assertTrue(m.transfer.value.active)
            exit.countDown(); m.waitForExit()
            assertFalse(File(root,stage).exists()); assertNull(m.storage.read(model)); assertFalse(m.transfer.value.active)
        } finally { exit.countDown(); root.deleteRecursively() }
    }
    @Test fun pauseWaitsForNoncancellableInstallerAndPreservesInstalledBytes() = runBlocking {
        val root = dir(); val entered = CompletableDeferred<Unit>(); val exit = CompletableDeferred<Unit>()
        try {
            File(root,model.filename).writeText("last usable")
            val m = ModelManager(root,ModelTransport { r,f,_ -> partial(r,f) },Dispatchers.Default,listOf(model),4,
                install = { _,_,_,p -> withContext(NonCancellable) { entered.complete(Unit); exit.await(); p.check() } })
            m.download(model); withTimeout(5000) { entered.await() }; m.discard(model)
            assertTrue(m.transfer.value.active); assertEquals("last usable",m.file(model).readText())
            exit.complete(Unit); m.waitForExit()
            assertFalse(m.transfer.value.active); assertEquals("last usable",m.file(model).readText()); assertNull(m.storage.read(model))
        } finally { exit.complete(Unit); root.deleteRecursively() }
    }
    @Test fun wrongRangesTotalsValidatorsAndCompressedMultipartResponsesNeverInstall() = runTest {
        val mutations: List<(TransferRequest,TransferResponse) -> TransferResponse> = listOf(
            { _,r -> r.copy(headers = r.headers+("Content-Range" to "bytes 1-4/${model.bytes}")) },
            { _,r -> r.copy(headers = r.headers+("Content-Range" to "bytes 0-3/999")) },
            { q,r -> if(q.start > 0) r.copy(headers = r.headers+("ETag" to "\"changed\"")) else r },
            { _,r -> r.copy(headers = r.headers+("Content-Encoding" to "gzip")) },
            { _,r -> r.copy(headers = r.headers+("Content-Type" to "multipart/byteranges")) },
            { _,r -> r.copy(headers = r.headers+("Content-Length" to "100")) },
        )
        for(mutate in mutations) {
            val root = dir()
            try {
                File(root,model.filename).writeText("usable")
                val m = ModelManager(root,ModelTransport { q,f,_ -> mutate(q,partial(q,f)) },StandardTestDispatcher(testScheduler),listOf(model),4)
                m.download(model); m.waitForExit()
                assertEquals("usable",m.file(model).readText()); assertTrue(m.transfer.value.message.contains("failed"))
            } finally { root.deleteRecursively() }
        }
    }
    @Test fun wholeFile200ReplacesPrefixAndChangedValidatorSafely() = runTest {
        val root = dir(); var n = 0
        try {
            val m = ModelManager(root,ModelTransport { q,f,_ ->
                if(n++ == 0) partial(q,f) else {
                    assertEquals(4L,q.start); assertEquals("\"revision1\"",q.validator)
                    f.writeBytes(bytes); TransferResponse(200,mapOf("ETag" to "\"revision2\""))
                }
            },StandardTestDispatcher(testScheduler),listOf(model),4)
            m.download(model); m.waitForExit(); assertArrayEquals(bytes,m.file(model).readBytes()); assertEquals(2,n)
        } finally { root.deleteRecursively() }
    }
    @Test fun range416RestartsOnceWithBoundedWholeRequest() = runTest {
        for(repeat416 in listOf(false,true)) {
            val root = dir(); var count = 0
            try {
                val m = ModelManager(root,ModelTransport { q,f,_ ->
                    count++
                    if(count == 1 || repeat416) TransferResponse(416,mapOf("Content-Range" to "bytes */${model.bytes}"))
                    else { assertTrue(q.full); assertEquals(0L,q.start); f.writeBytes(bytes); TransferResponse(200,emptyMap()) }
                },StandardTestDispatcher(testScheduler),listOf(model),4)
                m.download(model); m.waitForExit(); assertEquals(2,count)
                assertEquals(!repeat416,m.file(model).exists())
            } finally { root.deleteRecursively() }
        }
    }
    @Test fun interruptedManifestTailIsNotDurableAndIsTruncatedBeforeRetry() = runTest {
        val root = dir()
        try {
            val transport = ModelTransport { q,f,_ -> partial(q,f) }
            val m = ModelManager(root,transport,StandardTestDispatcher(testScheduler),listOf(model),4)
            var manifest = 0
            m.storage.fault = { if(it == "manifest" && ++manifest == 2) error("synthetic crash before journal publication") }
            m.download(model); m.waitForExit()
            val c = m.storage.read(model)!!; assertEquals(0L,c.offset); assertEquals(4L,File(root,c.stage).length())
            val next = ModelManager(root,ModelTransport { q,f,_ ->
                if(q.start == 0L) assertEquals(0L,File(root,c.stage).length())
                partial(q,f)
            },StandardTestDispatcher(testScheduler),listOf(model),4)
            next.download(model); next.waitForExit(); assertArrayEquals(bytes,next.file(model).readBytes())
        } finally { root.deleteRecursively() }
    }
    @Test fun failedHashResetsOwnedCheckpointWithoutRemovingInstalledBytes() = runTest {
        val root = dir()
        try {
            File(root,model.filename).writeText("last usable")
            val m = ModelManager(root,ModelTransport { _,f,_ -> f.writeBytes(ByteArray(bytes.size) { 1 }); TransferResponse(200,emptyMap()) },StandardTestDispatcher(testScheduler),listOf(model),4)
            m.download(model); m.waitForExit()
            assertEquals("last usable",m.file(model).readText()); assertEquals(0L,m.storage.read(model)!!.offset)
            m.discard(model); assertEquals("last usable",m.file(model).readText())
        } finally { root.deleteRecursively() }
    }
    @Test fun missingValidatorAndWeakEtagRequireWholeRestartAndStaleGenerationCannotAppend() = runTest {
        val root = dir(); val requests = mutableListOf<TransferRequest>()
        try {
            val m = ModelManager(root,ModelTransport { q,f,_ ->
                requests += q
                if(requests.size == 1) partial(q,f,"W/\"weak\"") else { assertTrue(q.full); f.writeBytes(bytes); TransferResponse(200,emptyMap()) }
            },StandardTestDispatcher(testScheduler),listOf(model),4)
            m.download(model); m.waitForExit(); assertArrayEquals(bytes,m.file(model).readBytes())
            m.file(model).delete()
            val stale = ModelManager(root,ModelTransport { q,f,_ ->
                val c = m.storage.read(model)!!
                m.storage.files.atomic(m.storage.journal(model),c.copy(generation = UUID.randomUUID().toString()).encode())
                partial(q,f)
            },StandardTestDispatcher(testScheduler),listOf(model),4)
            stale.download(model); stale.waitForExit(); assertFalse(stale.file(model).exists()); assertEquals(0L,stale.storage.read(model)!!.offset)
        } finally { root.deleteRecursively() }
    }

    @Test fun generationChangedAtJournalPublicationCannotBeOverwrittenAndScratchRecoveryIsExplicit() = runTest {
        val root = dir()
        try {
            val m = ModelManager(root,ModelTransport { q,f,_ -> partial(q,f) },StandardTestDispatcher(testScheduler),listOf(model),4)
            var saves = 0; var newer = ""
            m.storage.fault = {
                if(it == "manifest" && ++saves == 2) {
                    val c = m.storage.read(model)!!; newer = UUID.randomUUID().toString()
                    m.storage.files.atomic(m.storage.journal(model),c.copy(generation = newer).encode())
                }
            }
            m.download(model); m.waitForExit()
            assertEquals(newer,m.storage.read(model)!!.generation); assertEquals(0L,m.storage.read(model)!!.offset)
            val orphan = File(root,"chunk-${UUID.randomUUID()}.tmp").apply { writeText("orphan") }
            val stageOrphan = File(root,"part-${UUID.randomUUID()}").apply { writeText("old") }
            val unknown = File(root,"unrelated.txt").apply { writeText("preserve") }
            val resumed = ModelManager(root,ModelTransport { q,f,_ -> partial(q,f) },StandardTestDispatcher(testScheduler),listOf(model),4)
            assertTrue(orphan.exists()); assertTrue(stageOrphan.exists()) // Passive discovery never does network/cleanup work.
            resumed.download(model); resumed.waitForExit()
            assertFalse(orphan.exists()); assertFalse(stageOrphan.exists()); assertEquals("preserve",unknown.readText())
            assertArrayEquals(bytes,resumed.file(model).readBytes())
        } finally { root.deleteRecursively() }
    }
    @Test fun completedCheckpointAfterInstallCrashReverifiesWithoutNetworkOrSelection() = runTest {
        val root = dir(); var calls = 0
        try {
            val m = ModelManager(root,ModelTransport { q,f,_ -> calls++; partial(q,f) },StandardTestDispatcher(testScheduler),listOf(model),4,
                install = { part,dest,c,p -> p.commit { ModelCatalog.install(part,dest,c) }; throw CancellationException("synthetic publication crash") })
            m.download(model); m.waitForExit(); assertEquals(model.bytes,m.storage.read(model)!!.offset)
            assertArrayEquals(bytes,m.file(model).readBytes())
            val before = calls
            val resumed = ModelManager(root,ModelTransport { _,_,_ -> calls++; error("No request should run") },StandardTestDispatcher(testScheduler),listOf(model),4)
            assertEquals(before,calls)
            resumed.download(model); resumed.waitForExit(); assertEquals(before,calls); assertNull(resumed.storage.read(model))
            assertArrayEquals(bytes,resumed.file(model).readBytes())
        } finally { root.deleteRecursively() }
    }

    @Test fun deletionReservationSurvivesPauseUntilActualNativeQueueExit() = runBlocking {
        val root = dir(); val entered = CountDownLatch(1); val exit = CountDownLatch(1); var calls = 0
        var deletion: Deferred<Unit>? = null
        try {
            val m = ModelManager(root,ModelTransport { q,f,_ -> calls++; partial(q,f) },Dispatchers.Default,listOf(model),4)
            m.file(model).writeText("usable")
            NativeTasks.submit { entered.countDown(); check(exit.await(5,TimeUnit.SECONDS)) }
            assertTrue(withContext(Dispatchers.IO) { entered.await(5,TimeUnit.SECONDS) })
            deletion = async(Dispatchers.Default) { m.delete(model) }
            withTimeout(5000) { m.transfer.first { it.active && !it.pausable } }
            m.pause(); m.download(model); m.discard(model)
            assertEquals(0,calls); assertTrue(m.transfer.value.active); assertEquals("usable",m.file(model).readText())
            exit.countDown(); deletion.await(); assertFalse(m.file(model).exists()); assertFalse(m.transfer.value.active)
            m.download(model); m.waitForExit(); assertArrayEquals(bytes,m.file(model).readBytes())
        } finally { exit.countDown(); withContext(NonCancellable) { deletion?.await() }; root.deleteRecursively() }
    }
    @Test fun catalogTransportAdmitsOnlyCredentialFreeHttpsCatalogHostsAndStrongValidators() {
        assertTrue(CatalogHttpTransport.allowed(model.url)); assertTrue(CatalogHttpTransport.allowed("https://cdn.hf.co/file"))
        for(url in listOf("http://huggingface.co/x","https://huggingface.co.evil/x","https://user:secret@huggingface.co/x","https://huggingface.co:444/x","https://example.com/x")) assertFalse(url,CatalogHttpTransport.allowed(url))
        assertNull(TransferValidator.response(TransferResponse(206,mapOf("ETag" to "W/\"weak\"","Last-Modified" to "Wed, 21 Oct 2015 07:28:00 GMT","Date" to "Wed, 21 Oct 2015 07:30:00 GMT"))))
        assertEquals("modified",TransferValidator.response(TransferResponse(206,mapOf("Last-Modified" to "Wed, 21 Oct 2015 07:28:00 GMT","Date" to "Wed, 21 Oct 2015 07:30:00 GMT")))?.kind)
    }
}
