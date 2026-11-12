package dev.parla.android

import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class DictationFlowTest {
    @Test fun laterDiskFailureCannotLeaveADurableNoWriteClaim() = runBlocking {
        var durable: HistoryEntry? = null
        var writes = 0
        DictationFlow().run(PendingOperation(), LocalData(Settings(outputMode = "raw")), AppCategory.unknown, false, 0,
            transcribe = { "original" }, key = { error("raw mode needs no key") },
            save = { row, update -> if (!update) { durable = row; true } else false },
            deliver = { _, authorize -> if (authorize()) writes++; "Inserted" }, stage = { _, _ -> })
        assertEquals(1, writes)
        assertTrue(durable!!.note.contains("unconfirmed"))
        assertFalse(durable!!.note.contains("Nothing inserted yet"))
        assertEquals("Inserted", RecoveryVault.current()?.outcome)
        RecoveryVault.clear()
    }
    @Test fun productionFlowSavesBeforeDeliveryAndShapesAfterLockedSnippet() = runBlocking {
        val op = PendingOperation(); val events = mutableListOf<String>(); var persisted: HistoryEntry? = null
        val data = LocalData(snippets = listOf(Snippet(trigger = "signature",expansion = "Hello\nWorld")),replacements = listOf(LiteralReplacement("Hello","bad")))
        val result = DictationFlow().run(op,data,AppCategory.chat,false,100,
            transcribe = { events.add("asr"); "signature" },key = { error("locked snippets need no credential") },
            save = { row, existing -> events.add(if(existing) "update" else "save"); persisted = row; true },
            deliver = { text, authorize -> assertEquals("Hello World",persisted?.text); assertEquals("Hello World",text); assertTrue(authorize()); assertFalse(authorize()); events.add("write"); "Inserted" },
            stage = { _,_ -> })
        assertEquals(listOf("asr","save","update","write","update"),events)
        assertEquals("signature",result.raw); assertEquals("Hello World",result.text); assertEquals(PendingOperation.Stage.finished,op.stage)
        RecoveryVault.clear()
    }
    @Test fun productionFlowCancelDuringWriteVerificationKeepsResultOutcomeAndNeverReplays() = runBlocking {
        val op = PendingOperation(); val written = CompletableDeferred<Unit>(); var saved: HistoryEntry? = null; var writes = 0
        val job = launch {
            DictationFlow().run(op,LocalData(Settings(outputMode = "raw")),AppCategory.unknown,false,0,
                transcribe = { "raw 👋 नमस्ते" },key = { error("no key") },save = { row,_ -> saved = row; true },
                deliver = { _,authorize -> if(authorize()) writes++; written.complete(Unit); awaitCancellation() },stage = { _,_ -> })
        }
        written.await(); assertTrue(op.revoke()); job.cancelAndJoin()
        assertEquals(1,writes); assertEquals("raw 👋 नमस्ते",saved?.text)
        assertTrue(saved!!.note.contains("Text may have been inserted"))
        assertEquals(saved!!.text,RecoveryVault.current()?.result)
        assertTrue(RecoveryVault.current()!!.outcome.contains("may have been inserted")); assertFalse(op.authorizeDispatch())
        RecoveryVault.clear()
    }
    @Test fun historySuppressionUsesOnlyBoundedTransientResultAndSaveFailureDoesNotLoseIt() = runBlocking {
        suspend fun run(noHistory: Boolean): HistoryEntry {
            val op = PendingOperation()
            return DictationFlow().run(op,LocalData(Settings(outputMode = "raw",noHistory = noHistory)),AppCategory.unknown,false,0,
                transcribe = { "original" },key = { error("no key") },
                save = { _,_ -> check(!noHistory) { "private history must never reach persistence" }; false },
                deliver = { _,authorize -> assertTrue(authorize()); "Insertion uncertain; check editor" },stage = { _,_ -> })
        }
        val private = run(true); assertEquals(private.text,RecoveryVault.current()?.result)
        val failed = run(false); assertTrue(failed.note.contains("History was not saved")); assertEquals(failed.raw,RecoveryVault.current()?.original)
        RecoveryVault.clear()
    }
    @Test fun revokedRecognitionCannotCleanSaveOrDeliverEvenIfAdapterReturnsLate() = runBlocking {
        val op = PendingOperation(); val calls = AtomicBoolean(false)
        val error = runCatching {
            DictationFlow().run(op,LocalData(),AppCategory.unknown,false,0,
                transcribe = { op.revoke(); "late speech" },key = { calls.set(true); "bad" },
                save = { _,_ -> calls.set(true); true },deliver = { _,_ -> calls.set(true); "bad" },stage = { _,_ -> })
        }.exceptionOrNull()
        assertTrue(error is CancellationException); assertFalse(calls.get()); assertNull(op.prepared)
    }
}
