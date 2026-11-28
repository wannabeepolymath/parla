package dev.parla.android

import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class OriginalCopyTest {
    private var now = 1_000L
    private val timers = mutableListOf<Pair<Long,() -> Unit>>()
    private var canceled = 0
    private val owner = OriginalCopyOwner({ now }) { delay,action -> timers += delay to action; { canceled++ } }

    @Test fun originalIsClearedAtThirtySecondsWithoutAnyScreenOrRefresh() {
        val attempt = owner.dispatched(); now += 2_000
        assertTrue(owner.completed(attempt,"raw words"))
        val (delay,fire) = timers.single()
        assertEquals(28_000L,delay) // dispatch + 30 s, not completion + 30 s
        now = 31_000; fire()
        assertNull(owner.offer.value) // no refresh() or copy() was called
        // An older timer never clears a newer original; replacing or clearing cancels the pending timer.
        assertTrue(owner.completed(owner.dispatched(),"first"))
        val stale = timers.last().second; val before = canceled
        assertTrue(owner.completed(owner.dispatched(),"second")); assertEquals(before+1,canceled)
        stale(); assertNotNull(owner.offer.value)
        owner.clear(); assertEquals(before+2,canceled)
    }

    @Test fun originalExpiresThirtySecondsAfterDispatchAndReadingNeverRenewsIt() {
        val attempt = owner.dispatched()
        now += 2_000 // the write took a while; the deadline still counts from dispatch
        assertTrue(owner.completed(attempt,"raw words"))
        val offer = owner.offer.value!!
        assertEquals(1_000L+30_000,offer.expiresAt)
        now = 30_999; assertEquals("raw words",owner.copy(offer.token)); assertEquals("raw words",owner.copy(offer.token))
        now = 31_000
        assertNull(owner.copy(offer.token)); assertNull(owner.offer.value)
    }

    @Test fun anyClearBetweenDispatchAndCompletionWinsAndTokensAreSingleUse() {
        val stale = owner.dispatched()
        owner.clear() // setting turned off, new capture, form or microphone test
        assertFalse(owner.completed(stale,"raw")); assertNull(owner.offer.value)
        val first = owner.dispatched(); assertTrue(owner.completed(first,"first"))
        val token = owner.offer.value!!.token
        val second = owner.dispatched() // the next write invalidates the previous original at once
        assertNull(owner.copy(token))
        assertTrue(owner.completed(second,"second")); assertNull(owner.copy(token))
        assertEquals("second",owner.copy(owner.offer.value!!.token))
        val late = owner.dispatched(); now += 30_000
        assertFalse(owner.completed(late,"too late")); assertFalse(owner.completed(owner.dispatched(),""))
    }

    private var writes = 0
    private fun dictate(settings: Settings, authorize: Boolean = true, revokeDuringWrite: Boolean = false): String? = runBlocking {
        owner.clear()
        val op = PendingOperation()
        runCatching {
            DictationFlow(originals = owner).run(op,LocalData(settings),AppCategory.unknown,false,0,
                transcribe = { "um the raw words" },key = { error("no key") },save = { _,_ -> true },
                deliver = { _,write -> if(authorize && write()) writes++; if(revokeDuringWrite) op.revoke(); "Text inserted." },stage = { _,_ -> })
        }
        RecoveryVault.clear()
        owner.offer.value?.let { owner.copy(it.token) }
    }

    @Test fun dictationKeepsTheRawOriginalOnlyForAnOptedInDispatchedOrdinaryWrite() {
        assertEquals("um the raw words",dictate(Settings(outputMode = "raw")))
        assertEquals("um the raw words",dictate(Settings(outputMode = "raw",noHistory = true))) // independent of history
        assertNull(dictate(Settings(outputMode = "raw",keepLastOriginal = false)))
        val before = writes
        assertNull(dictate(Settings(outputMode = "selectedPreset",cleanupEnabled = false)))
        assertEquals(before+1,writes) // the preset write happened; only the original is withheld
        assertNull(dictate(Settings(outputMode = "raw"),authorize = false)) // nothing was written
        assertNull(dictate(Settings(outputMode = "raw"),revokeDuringWrite = true)) // canceled
        assertFalse(Settings().scratchpadSpelling); assertTrue(Settings().keepLastOriginal) // desktop defaults
    }
}
