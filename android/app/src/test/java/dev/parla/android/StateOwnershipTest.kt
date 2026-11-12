package dev.parla.android

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import kotlinx.coroutines.runBlocking

class StateOwnershipTest {
    private class Memory(var bytes: String? = null) : StateStorage {
        var fail = false; val backups = mutableListOf<String>(); var writes = 0
        override fun read() = bytes
        override fun write(value: String) { writes++; if(fail) error("disk full"); bytes = value }
        override fun preserveOriginal() { bytes?.let { backups.add(it) } }
    }
    @Test fun schemaMigrationPreservesLegacyDataAndDisablingIsNonDestructive() {
        val row = HistoryEntry(id = "one",raw = "old raw",text = "old result")
        val legacy = JSONObject(LocalDataCodec.encode(LocalData(dictionary = listOf("नमस्ते"),snippets = listOf(Snippet(id = "s",trigger = "email",expansion = "saved")),history = listOf(row))))
        legacy.put("version",1); legacy.getJSONObject("settings").put("transcriptionModel","old-cloud").put("style","Formal").put("noHistory",true).put("writingStyles",JSONObject().put("Other","Excited"))
        val decoded = LocalDataCodec.decode(legacy.toString())
        assertEquals(listOf(row),decoded.history); assertEquals("standard",decoded.settings.style)
        assertEquals(listOf("नमस्ते"),decoded.dictionary); assertEquals("saved",decoded.snippets.single().expansion)
        assertEquals("base.en",decoded.settings.localModel); assertEquals(50,decoded.settings.historyLimit)
        val source = Memory(LocalDataCodec.encode(decoded)); val state = LocalState(source)
        assertTrue(state.update { it.copy(settings = it.settings.copy(noHistory = false)) })
        assertEquals(listOf(row),state.data.value.history)
        assertFalse(source.bytes!!.contains("transcriptionModel")); assertFalse(source.bytes!!.contains("writingStyles"))
        assertTrue(state.update { it.copy(history = emptyList()) }); assertTrue(state.data.value.history.isEmpty())
    }
    @Test fun legacyHistoryCountSurvivesFirstSchemaTwoWrite() {
        val data = LocalData(history = (1..80).map { HistoryEntry(raw = "$it",text = "$it") })
        val legacy = JSONObject(LocalDataCodec.encode(data)).put("version",1)
        legacy.getJSONObject("settings").remove("historyLimit")
        val memory = Memory(legacy.toString()); val state = LocalState(memory)
        assertEquals(80,state.data.value.settings.historyLimit)
        assertTrue(state.update { it.copy(settings = it.settings.copy(noHistory = true)) })
        assertEquals(80,LocalDataCodec.decode(memory.bytes!!).history.size)
    }
    @Test fun actualPersistenceGateBlocksMalformedLoadAndPreservesOriginalOnRepair() {
        val source = Memory("{broken original"); val state = LocalState(source)
        assertTrue(state.blocked); assertNotNull(state.error.value)
        assertFalse(state.update { it.copy(dictionary = listOf("overwrite")) }); assertEquals(0,source.writes)
        assertFalse(state.repair("{}")); assertEquals("{broken original",source.bytes)
        assertTrue(state.repair(LocalDataCodec.encode(LocalData(dictionary = listOf("repaired")))))
        assertEquals(listOf("{broken original"),source.backups); assertFalse(state.blocked)
        assertEquals(listOf("repaired"),state.data.value.dictionary)
        source.bytes = "not JSON"; assertFalse(state.reload()); assertTrue(state.blocked)
    }
    @Test fun failedPersistenceNeverPublishesUnsavedStateAndCanReload() {
        val source = Memory(); val state = LocalState(source)
        source.fail = true
        assertFalse(state.update { it.copy(dictionary = listOf("unsaved")) }); assertTrue(state.data.value.dictionary.isEmpty()); assertNotNull(state.error.value)
        source.fail = false; assertTrue(state.update { it.copy(dictionary = listOf("saved")) })
        assertEquals(listOf("saved"),LocalState(source).data.value.dictionary)
    }
    @Test fun badSettingsTypesVersionAndOutOfRangeHistoryAreRejected() {
        for(json in listOf("{}","{\"version\":3,\"settings\":{}}","{\"version\":2,\"settings\":{\"baseUrl\":5}}","{\"version\":2,\"settings\":{\"historyLimit\":0}}")) assertTrue(json,runCatching { LocalDataCodec.decode(json) }.isFailure)
        val data = LocalData(settings = Settings(historyLimit = 1000,style = "formal"),dictionary = (1..1000).map { "w$it" },presets = listOf(TransformPreset(name = "Rewrite",instruction = "Be concise")),profiles = listOf(AppProfile(name = "Exact",target = "com.example.app")),replacements = listOf(LiteralReplacement("old","new")))
        assertEquals(data,LocalDataCodec.decode(LocalDataCodec.encode(data)))
        val state = LocalState(Memory())
        assertTrue(state.update { it.copy(history = (1..75).map { HistoryEntry(raw = "$it",text = "$it") }) }); assertEquals(50,state.data.value.history.size)
        assertTrue(state.update { it.copy(settings = it.settings.copy(historyLimit = 1)) }); assertEquals(1,state.data.value.history.size)
    }
    @Test fun cancellationAfterWritePreservesOneUseOutcomeAndReadyRecovery() {
        val op = PendingOperation(); op.advance(PendingOperation.Stage.ready)
        assertTrue(RecoveryVault.retain(op.id,"original","result","Ready",now = 100))
        assertTrue(op.authorizeDispatch()); assertFalse(op.authorizeDispatch()); assertTrue(op.revoke())
        RecoveryVault.outcome(op.id,"Insertion may have occurred; check editor")
        assertEquals("result",RecoveryVault.current(101)?.result); assertTrue(RecoveryVault.current(101)!!.outcome.contains("may have occurred"))
        assertFalse(op.authorizeDispatch()); op.advance(PendingOperation.Stage.finished); assertEquals(PendingOperation.Stage.discarded,op.stage)
        assertNull(RecoveryVault.current(300101)); RecoveryVault.clear()
        val before = PendingOperation(); assertFalse(before.revoke()); assertFalse(before.authorizeDispatch())
        assertFalse(RecoveryVault.retain("large","x".repeat(65536),"x","ready")); assertNull(RecoveryVault.current())
    }
    @Test fun concurrentHistoryRetryCannotOverwriteOrResurrectAndProposesBeforeApply() = runBlocking {
        val retry = HistoryRetry(); val row = HistoryEntry(raw = "cat",text = "old")
        val old = retry.begin(row); val current = retry.begin(row)
        assertFalse(retry.valid(old,row,listOf(row)))
        assertTrue(retry.valid(current,row,listOf(row)))
        val proposed = retry.propose(current,row,LocalData(Settings(cleanupEnabled = false),replacements = listOf(LiteralReplacement("cat","dog"))),{ error("no key") })
        assertEquals("dog",proposed.result); assertEquals("old",row.text); assertTrue(proposed.summary.contains("destination unknown"))
        assertFalse(retry.valid(current,row,listOf(row.copy(text = "newer",revision = 1))))
        retry.invalidate(row.id); assertFalse(retry.valid(current,row,listOf(row))); assertFalse(retry.valid(current,row,emptyList()))
        val next = retry.begin(row); retry.clear(); assertFalse(retry.valid(next,row,listOf(row)))
        assertTrue(exportHistory(listOf(row),true).contains("### Original\n\ncat")); assertTrue(exportHistory(listOf(row),false).contains("Original:\ncat"))
    }
}
