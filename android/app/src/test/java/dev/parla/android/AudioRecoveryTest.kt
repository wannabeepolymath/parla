package dev.parla.android

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.attribute.FileTime
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class AudioRecoveryTest {
    private class Fixture {
        val root = Files.createTempDirectory("parla-recovery-test").toFile().canonicalFile
        var now = 1_730_000_000_000L
        var data: LocalData? = LocalData()
        val audio = File(root,"capture.wav").apply {
            writeBytes(WavHeader.create(16000) + ByteBuffer.allocate(16000).order(ByteOrder.LITTLE_ENDIAN).apply { repeat(8000) { putShort(2000) } }.array())
        }
        fun store(limit: Long = 128L*1024*1024, remover: (File) -> Unit = { Files.delete(it.toPath()) }) = RecordingStore(File(root,"recordings"),{ data },{ now },limit,remover)
        fun close() { root.deleteRecursively() }
    }
    @Test fun migrationRequiresExistingUsersToOptInAndRetentionIsIndependentOfTextHistory() {
        assertTrue(Settings().recoveryAudioEnabled); assertEquals(7,Settings().recoveryAudioDays)
        for(version in 1..2) {
            val old = JSONObject(LocalDataCodec.encode(LocalData(settings = Settings(noHistory = true)))).put("version",version)
            val migrated = LocalDataCodec.decode(old.toString())
            assertFalse(migrated.settings.recoveryAudioEnabled); assertTrue(migrated.settings.noHistory)
            assertFalse(LocalDataCodec.decode(LocalDataCodec.encode(migrated)).settings.recoveryAudioEnabled)
        }
        val enabled = LocalData(settings = Settings(noHistory = true,recoveryAudioEnabled = true,recoveryAudioDays = 30))
        assertEquals(enabled,LocalDataCodec.decode(LocalDataCodec.encode(enabled)))
        for(days in listOf(0,31)) {
            val bad = JSONObject(LocalDataCodec.encode(enabled)); bad.getJSONObject("settings").put("recoveryAudioDays",days)
            assertTrue(runCatching { LocalDataCodec.decode(bad.toString()) }.isFailure)
        }
    }
    @Test fun productionCaptureFinalizationRetainsFailedRecognitionAndDisposesRawSuccessOrCancel() = runBlocking {
        val f = Fixture()
        try {
            val store = f.store()
            val failed = CaptureRecovery(store)
            failed.prepare(f.audio,false) { false }; failed.finish(false)
            val retained = store.descriptors().single(); assertNotNull(retained.seconds); assertEquals(.5,retained.seconds!!,0.0)
            val success = CaptureRecovery(store); success.prepare(f.audio,false) { false }; success.recognized("usable raw")
            // Cleanup/provider failure after usable raw must not make ASR look failed.
            runCatching { error("synthetic later cleanup failure") }; success.finish(false)
            assertEquals(listOf(retained.id),store.descriptors().map { it.id })
            val canceled = CaptureRecovery(store); canceled.prepare(f.audio,false) { false }; canceled.finish(true)
            assertEquals(1,store.descriptors().size)
            val private = CaptureRecovery(store); private.prepare(f.audio,true) { false }; private.finish(true)
            assertEquals(1,store.descriptors().size)
            f.data = f.data!!.copy(settings = f.data!!.settings.copy(noHistory = true))
            val independent = CaptureRecovery(store); independent.prepare(f.audio,false) { false }; independent.finish(false)
            assertEquals(2,store.descriptors().size)
        } finally { f.close() }
    }
    @Test fun blockedSettingsNeverAuthorizeNewStashOrRecoveryAndDoNotPruneFromFallback() {
        val f = Fixture()
        try {
            val store = f.store(); val lease = store.stash(f.audio,false)!!; store.release(lease)
            f.data = null
            assertNull(store.stash(f.audio,false)); assertTrue(runCatching { store.acquire(lease.file.name) }.isFailure)
            f.now += 31L*86_400_000
            assertEquals(0,store.prune().removed); assertTrue(lease.file.exists())
            assertEquals(1,store.descriptors().size)
        } finally { f.close() }
    }
    @Test fun quotaAndStorageFailuresAreExplicitAndSuccessfulRawSurvivesPurgeFailure() = runBlocking {
        val f = Fixture()
        try {
            val quota = f.store(10); assertNull(quota.stash(f.audio,false)); assertTrue(quota.error.value!!.contains("quota"))
            val store = f.store(remover = { error("synthetic disk refusal") })
            val capture = CaptureRecovery(store); capture.prepare(f.audio,false) { false }; capture.recognized("raw held")
            capture.finish(false)
            assertTrue(store.error.value!!.startsWith("Recognition succeeded")); assertEquals(1,store.descriptors().size)
            assertEquals(1,store.clear().failed)
        } finally { f.close() }
    }
    @Test fun pruningDeletionClearAndRevocationCannotInvalidateActiveOrNewerLeases() {
        val f = Fixture()
        try {
            val store = f.store(); val capture = store.stash(f.audio,false)!!
            assertEquals(1,store.delete(capture.file.name).busy); assertEquals(1,store.clear().busy)
            store.release(capture)
            val reader = store.acquire(capture.file.name); store.revoke(reader)
            assertEquals(1,store.delete(reader.file.name).busy); assertTrue(runCatching { store.validate(reader) }.isFailure)
            store.release(reader)
            val newer = store.acquire(reader.file.name)
            store.release(reader); store.resolve(reader,recognized = true)
            store.validate(newer); assertEquals(1,store.clear().busy)
            f.now += 8L*86_400_000; assertEquals(1,store.prune().busy); assertTrue(newer.file.exists())
            store.release(newer); assertEquals(1,store.prune().removed); assertFalse(newer.file.exists())
        } finally { f.close() }
    }
    @Test fun aliasesUnexpectedNamesCorruptOversizeAndInterruptedWavAreNeverAdmitted() {
        val f = Fixture()
        try {
            val store = f.store(); val capture = store.stash(f.audio,false)!!; store.release(capture)
            val id = capture.file.name
            Files.setLastModifiedTime(capture.file.toPath(),FileTime.fromMillis(1))
            val changed = store.acquire(id)
            capture.file.writeText("not a wav"); assertTrue(runCatching { store.validate(changed) }.isFailure); store.release(changed)
            assertNotNull(store.descriptors().single().reason); assertTrue(runCatching { store.acquire(id) }.isFailure)
            capture.file.delete(); Files.createSymbolicLink(capture.file.toPath(),f.audio.toPath())
            assertTrue(runCatching { store.acquire(id) }.isFailure); assertEquals(1,store.delete(id).failed)
            Files.delete(capture.file.toPath()); capture.file.writeBytes(ByteArray(WavInput.MAX_BYTES+1))
            assertTrue(runCatching { store.acquire(id) }.isFailure); Files.delete(capture.file.toPath())
            val partial = File(capture.file.parentFile,id+".partial").apply { writeBytes(f.audio.readBytes()) }
            assertNotNull(store.descriptors().single().reason); assertTrue(runCatching { store.acquire(partial.name) }.isFailure)
            assertTrue(runCatching { store.acquire("../capture.wav") }.isFailure)
            assertEquals(1,store.clear().removed); assertTrue(f.audio.exists())
        } finally { f.close() }
    }
    @Test fun serviceRecreationSweepsOnlyUnownedCacheAndNeverAnActiveRecoveryFile() {
        val f = Fixture()
        try {
            val directory = File(f.root,"cache")
            val active = CaptureAudio.reserve(directory).apply { writeText("active") }
            val abandoned = File(directory,"dictation-${UUID.randomUUID()}.wav").apply { writeText("orphan") }
            CaptureAudio.sweep(directory); assertTrue(active.exists()); assertFalse(abandoned.exists())
            CaptureAudio.release(active); assertFalse(active.exists())
            val store = f.store(); val capture = store.stash(f.audio,false)!!
            // A service recreation obtains the same production singleton; independent cache sweep cannot touch it.
            CaptureAudio.sweep(directory); assertTrue(capture.file.exists()); assertEquals(1,store.clear().busy)
            store.release(capture)
            val restarted = f.store(); assertEquals(capture.file.name,restarted.descriptors().single().id)
        } finally { f.close() }
    }
    @Test fun injectedPlaybackHasExclusiveLeaseAndStaleCallbacksCannotStopNewPlayback() {
        val f = Fixture()
        try {
            val store = f.store(); val capture = store.stash(f.audio,false)!!; store.release(capture)
            val callbacks = mutableListOf<(Boolean) -> Unit>(); var stops = 0
            val playback = RecoveryPlayback(store) { object : RecoveryPlayer {
                override fun play(file: File, completed: (Boolean) -> Unit) { callbacks += completed }
                override fun stop() { stops++ }
            } }
            playback.start(capture.file.name) { }; assertEquals(1,store.delete(capture.file.name).busy)
            playback.stop(); playback.start(capture.file.name) { }
            callbacks[0](true); assertEquals(capture.file.name,playback.id); assertEquals(1,store.clear().busy)
            callbacks[1](true); assertNull(playback.id); assertEquals(2,stops)
            assertEquals(1,store.delete(capture.file.name).removed)
        } finally { f.close() }
    }
    @Test fun localRetranscriptionFreezesSettingsRetainsSourceAndSavesOnlyExplicitly() = runTest {
        val f = Fixture(); val saved = mutableListOf<HistoryEntry>()
        try {
            f.data = LocalData(settings = Settings(noHistory = true,language = "hi"),dictionary = listOf("priority","second"))
            val store = f.store(); val capture = store.stash(f.audio,false)!!; store.release(capture)
            var frozen: LocalData? = null
            lateinit var recovery: AudioRecovery
            recovery = AudioRecovery(store,{ f.data },{ File(f.root,"fake-model") },{ saved += it; true },
                RecoveryRecognizer { _,_,_,data,validate ->
                    validate(); frozen = data; f.data = data.copy(dictionary = listOf("changed")); "original नमस्ते"
                },StandardTestDispatcher(testScheduler),drain = {
                    assertEquals("original नमस्ते",recovery.state.value.preview!!.text)
                    assertTrue(capture.file.exists()); assertEquals(1,store.delete(capture.file.name).busy)
                })
            recovery.transcribe(capture.file.name); recovery.waitForExit()
            assertEquals(listOf("priority","second"),frozen!!.dictionary); assertEquals("hi",frozen!!.settings.language)
            assertTrue(capture.file.exists()); assertTrue(saved.isEmpty())
            recovery.savePreview(); assertTrue(saved.isEmpty())
            f.data = f.data!!.copy(settings = f.data!!.settings.copy(noHistory = false)); recovery.savePreview()
            assertEquals("original नमस्ते",saved.single().raw); recovery.savePreview(); assertEquals(1,saved.size)
            recovery.close()
        } finally { f.close() }
    }
    @Test fun leavingRecoveryWithHistoryOffPreservesSourceForRecreatedScreenAndExplicitSave() = runTest {
        val f = Fixture(); val saved = mutableListOf<HistoryEntry>()
        try {
            f.data = LocalData(settings = Settings(noHistory = true))
            val store = f.store(); val capture = store.stash(f.audio,false)!!; store.release(capture)
            fun screen() = AudioRecovery(store,{ f.data },{ f.audio },{ saved += it; true },
                RecoveryRecognizer { _,_,_,_,validate -> validate(); "recovered original" },StandardTestDispatcher(testScheduler),drain = {})
            val first = screen(); first.transcribe(capture.file.name); first.waitForExit()
            first.savePreview(); assertTrue(saved.isEmpty())
            first.close() // Navigation to Privacy or activity recreation disposes the real screen controller.
            assertTrue(capture.file.exists()); assertEquals(capture.file.name,store.descriptors().single().id)
            f.data = f.data!!.copy(settings = f.data!!.settings.copy(noHistory = false))
            val recreated = screen(); recreated.transcribe(capture.file.name); recreated.waitForExit(); recreated.savePreview()
            assertEquals("recovered original",saved.single().raw); recreated.close()
            assertEquals(1,store.delete(capture.file.name).removed)
        } finally { f.close() }
    }
    @Test fun retranscriptionFailureCancellationBeforeDispatchAndFailedSavePreserveSourceOrPreview() = runTest {
        val f = Fixture()
        try {
            val store = f.store(); val capture = store.stash(f.audio,false)!!; store.release(capture)
            var calls = 0
            val failed = AudioRecovery(store,{ f.data },{ f.audio },{ false },RecoveryRecognizer { _,_,_,_,_ -> calls++; error("failure") },StandardTestDispatcher(testScheduler),drain = {})
            failed.transcribe(capture.file.name); failed.cancel(); failed.waitForExit()
            assertEquals(0,calls); assertTrue(capture.file.exists()); assertEquals(0,store.delete("../bad").removed)
            failed.transcribe(capture.file.name); failed.waitForExit(); assertEquals(1,calls); assertTrue(capture.file.exists())
            val success = AudioRecovery(store,{ f.data },{ f.audio },{ false },RecoveryRecognizer { _,_,_,_,validate -> validate(); "raw" },StandardTestDispatcher(testScheduler),drain = {})
            success.transcribe(capture.file.name); success.waitForExit(); success.savePreview()
            assertEquals("raw",success.state.value.preview!!.text); assertFalse(success.state.value.preview!!.saved)
            assertTrue(capture.file.exists()); failed.close(); success.close()
        } finally { f.close() }
    }
    @Test fun cancelingRetranscriptionWaitsForActualNativeExitBeforeReleasingLease() = runBlocking {
        val f = Fixture(); val entered = CountDownLatch(1); val exit = CountDownLatch(1)
        try {
            val store = f.store(); val capture = store.stash(f.audio,false)!!; store.release(capture)
            val recovery = AudioRecovery(store,{ f.data },{ f.audio },{ false },RecoveryRecognizer { _,_,_,_,validate ->
                withContext(Dispatchers.IO) { validate(); entered.countDown(); check(exit.await(5,TimeUnit.SECONDS)); "late raw" }
            },Dispatchers.Default,drain = {})
            recovery.transcribe(capture.file.name)
            assertTrue(withContext(Dispatchers.IO) { entered.await(5,TimeUnit.SECONDS) })
            recovery.cancel(); assertEquals(1,store.clear().busy)
            exit.countDown(); recovery.waitForExit()
            assertTrue(capture.file.exists()); assertNull(recovery.state.value.preview); assertEquals(1,store.clear().removed)
            recovery.close()
        } finally { exit.countDown(); f.close() }
    }
    @Test fun captureFinalizationWaitsForReaderDrainAndUnavailableSettingsRefuseQueuedRecognition() = runTest {
        val f = Fixture()
        try {
            val store = f.store(); val gate = CompletableDeferred<Unit>()
            val capture = CaptureRecovery(store,drain = { gate.await() })
            capture.prepare(f.audio,false) { false }
            val id = store.descriptors().single().id
            val finishing = launch { capture.finish(true) }; runCurrent()
            assertEquals(1,store.delete(id).busy); gate.complete(Unit); finishing.join(); assertTrue(store.descriptors().isEmpty())
            val source = store.stash(f.audio,false)!!; store.release(source)
            var entered = false
            val recovery = AudioRecovery(store,{ f.data },{ f.audio },{ false },RecoveryRecognizer { _,_,_,_,validate -> validate(); entered = true; "raw" },StandardTestDispatcher(testScheduler),drain = {})
            recovery.transcribe(source.file.name); f.data = null; recovery.waitForExit()
            assertFalse(entered); assertTrue(source.file.exists()); recovery.close()
        } finally { f.close() }
    }

    @Test fun canceledCaptureIntentSurvivesCrashAndPolicyFailureWhileRecoveryCancelPreservesSource() = runBlocking {
        val f = Fixture()
        try {
            val store = f.store(); val capture = store.stash(f.audio,false)!!
            store.cancelCapture(capture)
            assertTrue(File(capture.file.path+".discard").exists()); assertEquals(1,store.clear().busy)
            // New process has no reader; explicit durable cancellation remains authoritative without fallback policy.
            f.data = null
            val restarted = f.store(); assertTrue(restarted.descriptors().isEmpty()); assertFalse(capture.file.exists())
            store.release(capture)
        } finally { f.close() }
    }
    @Test fun actualSpeechNativeCancellationKeepsRecoveryLeaseUntilSerialBarrierExits() = runBlocking {
        val f = Fixture(); val entered = CountDownLatch(1); val exit = CountDownLatch(1); val released = CountDownLatch(1)
        var recovery: AudioRecovery? = null
        try {
            val bytes = "synthetic native model".toByteArray()
            val model = SpeechModel("fake","Fake",bytes.size.toLong(),MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
            val file = File(f.root,"model.bin").apply { writeBytes(bytes) }
            f.data = LocalData(settings = Settings(localModel = model.id))
            val store = f.store(); val capture = store.stash(f.audio,false)!!; store.release(capture)
            val fake = object : SpeechNative {
                override fun createToken() = 77L
                override fun cancel(token: Long) { }
                override fun release(token: Long) { released.countDown() }
                override fun recognize(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray {
                    entered.countDown(); check(exit.await(5,TimeUnit.SECONDS)); return "late raw".toByteArray()
                }
            }
            recovery = AudioRecovery(store,{ f.data },{ file },{ false },RecoveryRecognizer { audio,m,c,data,validate ->
                LocalSpeech(fake).transcribe(audio,m,c,data.dictionary,data.settings.language,validate)
            },Dispatchers.Default,catalog = listOf(model))
            recovery.transcribe(capture.file.name)
            assertTrue(withContext(Dispatchers.IO) { entered.await(5,TimeUnit.SECONDS) })
            recovery.cancel(); assertEquals(1L,released.count); assertEquals(1,store.clear().busy)
            assertTrue(capture.file.exists())
            exit.countDown(); recovery.waitForExit()
            assertEquals(0L,released.count); assertNull(recovery.state.value.preview)
            assertTrue(capture.file.exists()); assertEquals(1,store.clear().removed)
        } finally { exit.countDown(); recovery?.close(); withContext(NonCancellable) { recovery?.waitForExit() }; f.close() }
    }
    @Test fun dictionaryMovementReachesBothProductionHintBudgetsInSavedOrder() {
        val words = listOf("zebra","éclair","alpha")
        val moved = VocabularyHints.move(words,2,-1)
        assertEquals(listOf("zebra","alpha","éclair"),moved)
        assertEquals("zebra, alpha, éclair",VocabularyHints.asrPrompt(moved))
        assertEquals(moved,VocabularyHints.select(moved,8192))
        assertTrue(PromptBuilder.system(LocalData(dictionary = moved),AppCategory.unknown,false).contains("zebra, alpha, éclair"))
        val data = LocalData(dictionary = moved)
        assertEquals(moved,LocalDataCodec.decode(LocalDataCodec.encode(data)).dictionary)
        assertEquals(words,VocabularyHints.move(words,0,-1))
        assertTrue(VocabularyHints.select(listOf("👋".repeat(65),"valid"),2048) == listOf("valid"))
    }
}
