package dev.parla.android

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertFalse
import org.junit.Test

class SessionGateTest {
    /** Device F5: Finish (stopping = true), then cancel by switching apps. The gate must reopen once cleanup ends. */
    @Test fun canceledSessionReopensItsGateAfterNonCancellableCleanup() = runBlocking {
        var stopping = true
        val entered = CompletableDeferred<Unit>()
        val release = CompletableDeferred<Unit>()
        val session = launch {
            try { awaitCancellation() } finally {
                finishSession({ entered.complete(Unit); release.await() }) { stopping = false }
            }
        }
        yield()
        session.cancel()
        // Cleanup is in flight and cannot return yet, so the canceled caller is suspended in withContext.
        entered.await()
        release.complete(Unit)
        session.join()
        assertFalse("a canceled session must not leave the service refusing every tap", stopping)
    }
}
