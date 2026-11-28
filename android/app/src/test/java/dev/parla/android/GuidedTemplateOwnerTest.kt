package dev.parla.android

import kotlinx.coroutines.*
import kotlinx.coroutines.test.*
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class GuidedTemplateOwnerTest {
    private val a = GuidedTemplateField(key = "a",label = "Name")
    private val b = GuidedTemplateField(key = "b",label = "Notes",required = false)
    private val definition = GuidedTemplateDefinition(name = "Visit",body = "Name: {{a}}\nNotes: {{b}}",fields = listOf(a,b))
    private var config = TemplateConfig(ModelCatalog.all.first(),"auto",listOf("Parla"))
    private var document = GuidedTemplateDocument(listOf(definition))
    private var now = 0L
    /** Each take waits for Stop, then returns the next scripted result (or throws it). */
    private val results = ArrayDeque<Result<String>>()
    private var takes = 0; private var released = 0

    private fun TestScope.owner() = GuidedTemplateOwner(backgroundScope,{ now },{ config to document },take = { _,stop ->
        takes++
        try { stop.await(); results.removeFirst().getOrThrow() } finally { released++ }
    },date = { 42L })

    @Test fun anImportedModelIsFrozenWithItsIdentityAndAReplacedImportCancelsTheForm() = runTest(UnconfinedTestDispatcher()) {
        val imported = SpeechModel(SpeechModel.IMPORTED_ID,"Mine",1,"","11111111-1111-1111-1111-111111111111")
        val installed = java.io.File.createTempFile("model",".bin").apply { deleteOnExit() }
        config = config.copy(model = imported)
        val owner = owner(); owner.begin(definition)
        // Each take records with the frozen import itself, never a catalog lookup by id.
        assertEquals(imported,owner.state.value.config!!.installedModel { m -> if(m == imported) installed else java.io.File("missing") })
        config = config.copy(model = imported.copy(importID = "22222222-2222-2222-2222-222222222222")); owner.observe()
        assertEquals("Form canceled because settings changed.",owner.state.value.message)
        installed.delete()
    }

    @Test fun recordAcceptSkipReviewFinishAndSaveOnce() = runTest(UnconfinedTestDispatcher()) {
        val owner = owner(); results += Result.success("Ada Lovelace")
        owner.begin(definition)
        owner.start()
        assertTrue(owner.state.value.recording)
        owner.accept(); assertNull(owner.state.value.session!!.accepted[a.id]) // nothing to accept while recording
        owner.stop(); advanceUntilIdle()
        var run = owner.state.value
        assertFalse(run.recording || run.busy); assertEquals("Ada Lovelace",run.session!!.candidate)
        owner.editCandidate("Ada  Lovelace\n"); owner.accept()
        assertEquals(1,owner.state.value.session!!.index)
        owner.skip(); owner.review()
        val preview = owner.state.value.session!!.preview!!
        assertEquals("Name: Ada  Lovelace\n\nNotes: ",preview.body) // literal, never cleaned up
        owner.approve(preview.id)
        assertEquals(preview.body,owner.copy())
        val written = mutableListOf<HistoryEntry>()
        owner.save(historyOff = true) { written += it; true }; assertTrue(written.isEmpty())
        owner.save(historyOff = false) { written += it; true }
        owner.save(historyOff = false) { written += it; true }
        run = owner.state.value
        assertEquals(1,written.size); assertTrue(run.session!!.saved)
        assertEquals(preview.body,written[0].raw); assertEquals(preview.body,written[0].text); assertEquals(42L,written[0].createdAt)
        assertEquals(1,released)
    }

    @Test fun cancelClearsEveryTransientValueAndALateResultCannotResurrectIt() = runTest(UnconfinedTestDispatcher()) {
        val gate = CompletableDeferred<String>()
        val owner = GuidedTemplateOwner(backgroundScope,{ now },{ config to document },take = { _,stop -> stop.await(); withContext(NonCancellable) { gate.await() } })
        owner.begin(definition); owner.start(); owner.stop()
        assertTrue(owner.state.value.busy)
        owner.cancel()
        assertEquals(TemplateRun(message = "Form canceled."),owner.state.value)
        gate.complete("late"); advanceUntilIdle()
        assertEquals(TemplateRun(message = "Form canceled."),owner.state.value)
        owner.start(); owner.accept(); owner.review() // no session: every action is inert
        assertNull(owner.state.value.session)
    }

    @Test fun discardDuringRecordingOrRecognitionDropsOnlyThatTake() = runTest(UnconfinedTestDispatcher()) {
        val owner = owner()
        owner.begin(definition); owner.start()
        owner.discardTake(); advanceUntilIdle()
        var run = owner.state.value
        assertFalse(run.recording); assertNull(run.session!!.take); assertNull(run.session!!.candidate); assertEquals(1,released)
        results += Result.success("second")
        owner.start(); assertEquals(2,owner.state.value.session!!.starts)
        owner.stop(); advanceUntilIdle()
        assertEquals("second",owner.state.value.session!!.candidate)
        owner.discardTake() // no take: discards the unaccepted candidate
        run = owner.state.value
        assertNull(run.session!!.candidate); assertTrue(run.session!!.accepted.isEmpty())
    }

    @Test fun takeFailureAndLeavingTheScreenSettleWithoutACandidate() = runTest(UnconfinedTestDispatcher()) {
        val owner = owner(); results += Result.failure(GuidedTemplateFailure("Recording stopped or hit the time limit. Record the field again."))
        owner.begin(definition); owner.start(); owner.stop(); advanceUntilIdle()
        assertNull(owner.state.value.session!!.candidate)
        assertEquals("Recording stopped or hit the time limit. Record the field again.",owner.state.value.message)
        owner.start(); owner.pause()
        assertFalse(owner.state.value.recording); assertNull(owner.state.value.session!!.take)
        assertNotNull(owner.state.value.session) // the form itself survives
    }

    @Test fun savedChangesOrExpiryCancelTheForm() = runTest(UnconfinedTestDispatcher()) {
        val owner = owner()
        owner.begin(definition); owner.observe(); assertNotNull(owner.state.value.session)
        config = config.copy(dictionary = listOf("Parla","Ada")); owner.observe()
        assertEquals(TemplateRun(message = "Form canceled because settings changed."),owner.state.value)
        config = config.copy(dictionary = listOf("Parla"))
        owner.begin(definition)
        document = GuidedTemplateDocument(listOf(definition.copy(revision = java.util.UUID.randomUUID()))); owner.start()
        assertEquals("Form canceled because settings changed.",owner.state.value.message); assertNull(owner.state.value.session)
        document = GuidedTemplateDocument(listOf(definition))
        owner.begin(definition); now = GuidedTemplateSession.LIFETIME_MS; owner.start()
        assertEquals(TemplateRun(message = "Form expired after 20 minutes."),owner.state.value)
        now = 0; owner.begin(definition.copy(name = "Not saved")) // a definition that isn't in the saved document
        assertNull(owner.state.value.session)
    }
}
