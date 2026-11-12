package dev.parla.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import java.io.File
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Assume.assumeFalse
import org.junit.Test
import org.junit.runner.RunWith

/** Synthetic text only. These tests never start the microphone or call a provider. */
@RunWith(AndroidJUnit4::class)
class DeviceSafetyTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context = instrumentation.targetContext

    @Test fun keyRoundTripsEncryptedAndCorruptionHasAnActionableRecovery() {
        val store = Store.get(context)
        // Never overwrite a key supplied by a person on a reused device.
        assumeFalse("A user key is already present", store.hasKey)
        val file = File(context.noBackupFilesDir, "provider-key.enc")
        val synthetic = "synthetic-device-test-key-never-sent"
        try {
            store.saveKey(synthetic)
            assertEquals(synthetic, store.readKey())
            assertFalse(file.readBytes().toString(Charsets.UTF_8).contains(synthetic))
            file.writeBytes(byteArrayOf(0, 1, 2))
            val failure = runCatching { store.readKey() }.exceptionOrNull()
            assertTrue(failure is IllegalStateException)
            assertTrue(failure!!.message!!.contains("Remove it"))
        } finally {
            store.saveKey("")
        }
        assertFalse(store.hasKey)
    }

    @Test fun stoppingBeforeStartupDoesNotOpenMicrophoneOrCreateAudio() = runBlocking {
        val file = File(context.cacheDir, "synthetic-stopped-recording.wav")
        assertFalse(file.exists())
        val recorder = WavRecorder(context)
        recorder.stop()
        val failure = runCatching { recorder.record(file) {} }.exceptionOrNull()
        assertTrue(failure is IllegalStateException)
        assertTrue(failure!!.message!!.contains("stopped before it began"))
        assertFalse(file.exists())
    }

}
