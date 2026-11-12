package dev.parla.android

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Test

@OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
class InsertionLeaseTest {
    @Test fun editorInvalidationCancelsPendingWorkBeforeItCanProduceAResult() = runTest {
        val provider = CompletableDeferred<String>()
        var result: String? = null
        var stopped = false
        val work = launch(start = CoroutineStart.UNDISPATCHED) {
            try { result = provider.await() } finally { stopped = true }
        }
        var cancellations = 0
        val lease = InsertionLease { cancellations++; work.cancel() }
        lease.invalidate()
        lease.invalidate()
        provider.complete("must not be inserted")
        runCurrent()
        assertTrue(work.isCancelled)
        assertTrue(stopped)
        assertNull(result)
        assertEquals(1, cancellations)
        assertFalse(lease.consume())
    }

    @Test fun consumingBeforeAWriteIgnoresItsOwnEditorCallbacksAndCannotWriteTwice() {
        var cancelled = false
        val lease = InsertionLease { cancelled = true }
        assertTrue(lease.consume())
        lease.invalidate() // Synchronous or queued callbacks caused by our insertion.
        assertFalse(cancelled)
        assertFalse(lease.consume())
    }

    @Test fun releasingASessionDoesNotCancelAnyLaterWork() {
        var cancellations = 0
        val old = InsertionLease { cancellations++ }
        old.release()
        old.invalidate()
        val next = InsertionLease { cancellations++ }
        assertFalse(old.consume())
        assertTrue(next.consume())
        assertEquals(0, cancellations)
    }
}
