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
        // A synthetic scope no person would configure, so a real saved key is never touched.
        val scope = "openai-compatible|https://synthetic-device-test.invalid/v1"
        assumeFalse("A synthetic key is already present", store.hasKey(scope))
        val synthetic = "synthetic-device-test-key-never-sent"
        try {
            store.saveKey(scope, synthetic)
            assertEquals(synthetic, store.readKey(scope))
            assertEquals("", store.readKey("openai-compatible|https://other-synthetic.invalid/v1"))
            val name = java.security.MessageDigest.getInstance("SHA-256").digest(scope.toByteArray()).joinToString("") { "%02x".format(it) }
            val file = File(File(context.noBackupFilesDir, "provider-keys"), "$name.key")
            assertFalse(file.readBytes().toString(Charsets.UTF_8).contains(synthetic))
            file.writeBytes(byteArrayOf(0, 1, 2))
            val failure = runCatching { store.readKey(scope) }.exceptionOrNull()
            assertTrue(failure is IllegalStateException)
            assertTrue(failure!!.message!!.contains("Remove it"))
        } finally {
            store.removeKey(scope)
        }
        assertFalse(store.hasKey(scope))
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

    /** Android's ICU regex engine, not the JVM's: 1.3.2 crashed at DictionaryLearner init on a pattern JVM tests accepted. */
    @Test fun textRegexesCompileAndMatchOnIcu() {
        assertEquals("Sinead", DictionaryLearner.propose("Meet Shunade now", "Meet Shunade now", "Meet Sinead now", emptyList())?.to)
        assertEquals(listOf("New York"), VocabularyHints.select(listOf(" New　York "), 2048))
        assertEquals(3, TextRules.wordCount("one two three"))
        assertEquals("hi there", TextRules.stripNonSpeech("hi [music] there"))
        assertEquals("1250 pound", WER.normalize("1,250 pounds"))
        assertEquals("420 dollar", WER.normalize("$420"))
        assertEquals("the 21", WER.normalize("the twenty first"))
        assertEquals(1, "é".countCharacters())
        val editor = EditorSnapshot("dev.test", 1, "e", "1", "EditText", "alpha omega", 6, 6,
            editable = true, enabled = true, focused = true, visible = true, inputType = 1, password = false)
        assertEquals("middle ", InsertionPolicy.separated(editor, "middle"))
    }

}
