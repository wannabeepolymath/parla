package dev.parla.android

import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** P1-08: durable copy, quotas, recovery of interrupted jobs and writes, deletion and history association. */
class SavedImportStoreTest {
    private val root = Files.createTempDirectory("parla-saved").toFile()
    private val dir = File(root, "saved")
    private var now = 1_000_000_000L
    private fun store() = SavedImportStore(dir) { now }.also { it.load() }
    private fun source(bytes: Int = 1000, seed: Int = 0) = File(root, "src-${UUID.randomUUID()}").apply { writeBytes(ByteArray(bytes) { (it + seed).toByte() }) }
    private fun failure(block: () -> Unit) = (runCatching(block).exceptionOrNull() as? SavedImportStore.Failure)?.message
    @After fun clean() { root.deleteRecursively() }

    @Test fun admitKeepsAVerifiedCopyAndAcceptsOneResultPerAttempt() {
        val s = store()
        val original = source()
        val token = s.admit(original, "Interview\u0000.wav")
        original.delete() // the kept copy is independent of the chosen file
        assertEquals(SavedImportStore.State.queued, s.rows.value.single().state)
        assertEquals("Interview .wav", s.rows.value.single().label)
        s.running(token)
        assertEquals(1000L, s.source(token).length())
        val id = UUID.randomUUID().toString()
        val result = s.saveResult(token, id, "hello", "base.en", "en", now)
        assertEquals(result, s.saveResult(token, id, "hello", "base.en", "en", now)) // storage-only retry is idempotent
        assertEquals(SavedImportStore.State.committed, s.rows.value.single().state)
        assertEquals("hello", s.openResult(token.job).second)
        // A reopened store sees the same ledger and payloads.
        assertEquals("hello", store().openResult(token.job).second)
    }

    @Test fun quotasLimitJobsSourcesAndResults() {
        val s = store()
        repeat(SavedImportStore.MAX_JOBS) { s.finish(s.admit(source(seed = it), "f$it"), canceled = false) }
        assertEquals(SavedImportStore.MAX_JOBS, s.rows.value.size)
        assertTrue(failure { s.admit(source(), "one more") }!!.contains("up to 10"))
        s.delete(s.rows.value.first().id)
        val token = s.admit(source(), "fits again")
        assertTrue(failure { s.saveResult(token, UUID.randomUUID().toString(), "x".repeat(SavedImportStore.MAX_RESULT + 1), "m", "en", now) } != null)
        assertTrue(failure { s.saveResult(token, UUID.randomUUID().toString(), "   ", "m", "en", now) } != null)
        s.finish(token, canceled = true)
        assertEquals(SavedImportStore.State.canceled, s.rows.value.first { it.id == token.job }.state)
        s.delete(token.job)
        assertTrue(failure { s.admit(source(SavedImportStore.MAX_SOURCE + 1), "big") }!!.contains("20 MB"))
        assertEquals(2L * 65_536 + 4096 + 10 * 4096 + 1_048_576 + 30, SavedImportStore.charge(listOf(
            SavedImportStore.Job(UUID.randomUUID().toString(), "a", 0, 20, "0".repeat(64), SavedImportStore.State.committed, 1,
                SavedImportStore.Result(UUID.randomUUID().toString(), 1, 10, "0".repeat(64), 0, "m", "en", SavedImportStore.Association.notSaved)))))
    }

    @Test fun interruptedJobsAreShownAsInterruptedAndRetryMakesOldAttemptsStale() {
        val token = store().admit(source(), "f").also { store().running(it) } // a new process sees the same ledger
        val reopened = store()
        assertEquals(SavedImportStore.State.interrupted, reopened.rows.value.single().state)
        assertTrue(reopened.rows.value.single().sourceAvailable)
        val retry = reopened.begin(token.job)
        assertEquals(token.attempt + 1, retry.attempt)
        assertNotNull(failure { reopened.saveResult(token, UUID.randomUUID().toString(), "late", "m", "en", now) })
        assertNotNull(failure { reopened.delete(token.job) }) // the active attempt must be canceled first
        reopened.saveResult(retry, UUID.randomUUID().toString(), "fresh", "m", "en", now)
        assertEquals("fresh", reopened.openResult(token.job).second)
    }

    @Test fun recoveryFinishesStagingAndDeletionAndRemovesOnlyItsOwnOrphans() {
        val s = store()
        val token = s.admit(source(), "keep"); s.finish(token, false)
        val staging = UUID.randomUUID().toString(); val deleting = UUID.randomUUID().toString()
        val jobs = s.rows.value.map { r -> SavedImportStore.Job(r.id, r.label, r.created, r.sourceBytes, SavedImportStore.digest(File(dir, "${r.id}.source").readBytes()), SavedImportStore.State.failed, 1, null) } +
            SavedImportStore.Job(staging, "staging", now, 5, "0".repeat(64), SavedImportStore.State.staging, 0, null) +
            SavedImportStore.Job(deleting, "deleting", now, 5, "0".repeat(64), SavedImportStore.State.deleting, 1, null)
        File(dir, "manifest.json").writeText(SavedImportStore.encode(jobs))
        File(dir, "$staging.source").writeText("half")
        File(dir, "$deleting.source").writeText("gone")
        File(dir, "${token.job}.${UUID.randomUUID()}.txt").writeText("unaccepted result") // written before a ledger update that never landed
        File(dir, "journal-${UUID.randomUUID()}.tmp").writeText("torn")
        val recovered = store()
        assertNull(recovered.failure.value)
        assertEquals(listOf(token.job), recovered.rows.value.map { it.id })
        assertEquals(setOf("manifest.json", "${token.job}.source"), dir.list()!!.toSet())
        // An unknown file is never swept: everything is kept and the store refuses to run.
        File(dir, "notes.txt").writeText("user data")
        val refused = store()
        assertNotNull(refused.failure.value); assertTrue(File(dir, "notes.txt").exists()); assertTrue(File(dir, "${token.job}.source").exists())
        assertNotNull(failure { refused.admit(source(), "x") })
    }

    @Test fun expiryClockAndStrictLedgerRefusals() {
        val s = store(); s.finish(s.admit(source(), "old"), false)
        now += SavedImportStore.TTL_MS - 1
        assertEquals(1, store().rows.value.size)
        now += 1
        assertTrue(store().rows.value.isEmpty()); assertEquals(setOf("manifest.json"), dir.list()!!.toSet())
        val t = store().admit(source(), "clock"); store().finish(t, false)
        now -= 1000
        assertTrue(store().failure.value!!.contains("clock"))
        now += 1000
        val manifest = File(dir, "manifest.json").readText()
        for(bad in listOf(manifest.replace("\"failed\"", "\"interrupted\""), manifest.replace("\"failed\"", "\"weird\""), manifest.replace("\"schema\":1", "\"schema\":2"), manifest.replace("\"attempt\":1", "\"attempt\":\"1\""))) {
            assertNotEquals(manifest, bad)
            File(dir, "manifest.json").writeText(bad); assertNotNull(store().failure.value)
        }
    }

    @Test fun historyAssociationIsDurableIntentFirst() {
        val s = store(); val token = s.admit(source(), "f"); s.running(token)
        val id = UUID.randomUUID().toString()
        s.saveResult(token, id, "text", "m", "en", now)
        s.association(token.job, id, SavedImportStore.Association.savingIntent)
        // A crash between intent and history write leaves savingIntent, which the screen resolves with Check history.
        assertEquals(SavedImportStore.Association.savingIntent, store().openResult(token.job).first.association)
        assertNotNull(failure { s.association(token.job, UUID.randomUUID().toString(), SavedImportStore.Association.saved) })
        s.association(token.job, id, SavedImportStore.Association.saved)
        assertEquals(SavedImportStore.Association.saved, store().rows.value.single().result!!.association)
    }
}
