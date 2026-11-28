package dev.parla.android

import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.yield
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SessionGateTest {
    /** Device F5: Finish (stopping = true), then cancel by switching apps. The gate must reopen once cleanup ends. */
    @Test fun canceledSessionReopensItsGateAfterNonCancellableCleanup() = runBlocking {
        var stopping = true
        var cleaned = false
        val session = launch {
            try { awaitCancellation() } finally { finishSession({ cleaned = true }) { stopping = false } }
        }
        yield()
        session.cancelAndJoin()
        assertTrue("cleanup still runs on cancel", cleaned)
        assertFalse("a canceled session must not leave the service refusing every tap", stopping)
    }
}
