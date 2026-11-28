package dev.parla.android

import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import kotlinx.coroutines.runBlocking
import org.junit.Assert.*
import org.junit.Test

class SafeStartTest {
    private val base = ModelCatalog.all[0]
    private val small = ModelCatalog.all[1]
    private fun withJournal(test: (DurableFile, File) -> Unit) {
        val dir = Files.createTempDirectory("parla-safe-start").toFile()
        try { test(DurableFile(File(dir,"safe-start.json")),dir) } finally { dir.deleteRecursively() }
    }
    /** A later process opening the same journal. */
    private fun relaunch(j: DurableFile) = SafeStart(j,java.util.UUID.randomUUID().toString())
    private fun crashDuring(j: DurableFile, m: SpeechModel) { relaunch(j).begin(m) } // begin, then the process dies

    @Test fun offByDefaultTracksNothing() = withJournal { j,_ ->
        val s = SafeStart(j)
        assertFalse(s.state.value.enabled)
        assertNull(s.begin(base)); s.end(null)
        assertFalse(j.baseFile.exists())
        crashDuring(j,base); assertEquals(0,relaunch(j).crashes(base))
    }
    @Test fun pendingMarkerIsDurableBeforeNativeWorkAndClearedByItsReturn() = withJournal { j,_ ->
        val s = SafeStart(j); assertTrue(s.setEnabled(true))
        val mark = s.begin(base)
        assertTrue(j.read()!!.toString(Charsets.UTF_8).contains("\"pending\""))
        assertFalse("disabling is refused while native work runs",s.setEnabled(false))
        s.end(mark)
        assertFalse(j.read()!!.toString(Charsets.UTF_8).contains("pending"))
        assertEquals("a clean return never counts",0,relaunch(j).crashes(base))
        assertFalse(relaunch(j).takeNotice())
    }
    @Test fun twoUnfinishedAttemptsPauseOnlyThatModelUntilExplicitRetryOrReset() = withJournal { j,_ ->
        assertTrue(SafeStart(j).setEnabled(true))
        crashDuring(j,base)
        val afterOne = relaunch(j)
        assertEquals(1,afterOne.crashes(base)); assertFalse(afterOne.paused(base))
        assertTrue("next launch offers recovery",afterOne.takeNotice()); assertFalse("once",afterOne.takeNotice())
        crashDuring(j,base)
        val paused = relaunch(j)
        assertEquals(2,paused.crashes(base)); assertTrue(paused.paused(base))
        assertEquals(SafeStart.PAUSED,runCatching { paused.begin(base) }.exceptionOrNull()?.message)
        assertEquals("never loops: a paused model stays paused across launches",2,relaunch(j).crashes(base))
        paused.end(paused.begin(small)) // other models are unaffected
        // Try loading once: allowed while paused; a return clears the record.
        paused.end(paused.begin(base,retry = true))
        assertEquals(0,paused.crashes(base)); paused.end(paused.begin(base))
        // A crash during the one retry is counted, so the model is paused again rather than retried.
        crashDuring(j,base); crashDuring(j,base)
        val forget = relaunch(j); assertTrue(forget.paused(base))
        assertTrue(forget.reset()); assertFalse(forget.paused(base)); assertEquals(0,relaunch(j).crashes(base))
    }
    @Test fun previewDraftsBetweenFinalCrashesDoNotEraseThem() = withJournal { j,dir ->
        runBlocking {
            val bytes = "model".toByteArray()
            val m = SpeechModel("base.en","Fake",bytes.size.toLong(),java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
            val file = File(dir,"model.bin").apply { writeBytes(bytes) }
            val native = object : SpeechNative {
                override fun createToken() = 1L
                override fun cancel(token: Long) {}
                override fun release(token: Long) {}
                override fun recognize(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray) = "draft".toByteArray()
            }
            assertTrue(SafeStart(j).setEnabled(true))
            repeat(2) { launch ->
                val s = relaunch(j)
                assertEquals(launch,s.crashes(m))
                // Preview on the same model returns successfully while recording...
                assertEquals("draft",LocalSpeech(native,s).draft(FloatArray(16000) { .1f },file,m,emptyList(),"en",verify = true))
                assertEquals("a returning draft keeps the final path's history",launch,s.crashes(m))
                s.begin(m) // ...then the final recognition takes the process down.
            }
            val s = relaunch(j)
            assertTrue(s.paused(m))
            assertEquals(SafeStart.PAUSED,runCatching { LocalSpeech(native,s).draft(FloatArray(16000),file,m,emptyList(),"en",verify = true) }.exceptionOrNull()?.message)
        }
    }
    @Test fun recordsAreBoundToTheModelIdentityNotItsName() = withJournal { j,_ ->
        assertTrue(SafeStart(j).setEnabled(true))
        val a = SpeechModel(SpeechModel.IMPORTED_ID,"Mine",1,"",java.util.UUID.randomUUID().toString())
        crashDuring(j,a); crashDuring(j,a)
        val s = relaunch(j)
        assertTrue(s.paused(a))
        assertFalse("a re-import is a new identity",s.paused(a.copy(importID = java.util.UUID.randomUUID().toString())))
        assertFalse(s.paused(base.copy(sha256 = "0".repeat(64))))
    }
    @Test fun unreadableJournalRefusesNativeWorkUntilReset() = withJournal { j,_ ->
        j.write("{not json".toByteArray())
        val s = SafeStart(j)
        assertTrue(s.state.value.fault)
        assertEquals(SafeStart.UNAVAILABLE,runCatching { s.begin(base) }.exceptionOrNull()?.message)
        assertTrue(s.reset()); s.end(s.begin(base))
        assertTrue(s.setEnabled(false)); assertFalse(j.baseFile.exists()); assertNull(s.begin(base))
    }
    @Test fun localSpeechWritesTheMarkerAroundNativeAndRefusesAPausedModel() = withJournal { j,dir ->
        runBlocking {
            val bytes = "model".toByteArray()
            val m = SpeechModel("fake","Fake",bytes.size.toLong(),java.security.MessageDigest.getInstance("SHA-256").digest(bytes).joinToString("") { "%02x".format(it) })
            val file = File(dir,"model.bin").apply { writeBytes(bytes) }
            val samples = FloatArray(8000) { .1f }
            val s = SafeStart(j); assertTrue(s.setEnabled(true))
            var calls = 0; var pendingDuringNative = false
            val native = object : SpeechNative {
                override fun createToken() = 1L
                override fun cancel(token: Long) {}
                override fun release(token: Long) {}
                override fun recognize(token: Long, model: ByteArray, samples: FloatArray, prompt: ByteArray, language: ByteArray): ByteArray? {
                    calls++; pendingDuringNative = j.read()!!.toString(Charsets.UTF_8).contains("\"pending\""); return "hello".toByteArray()
                }
                override fun prepare(model: ByteArray) = true
            }
            assertEquals("hello",LocalSpeech(native,s).transcribe(samples,file,m,emptyList(),"en"))
            assertTrue(pendingDuringNative); assertEquals(0,relaunch(j).crashes(m))
            crashDuring(j,m); crashDuring(j,m)
            val paused = relaunch(j)
            assertEquals(SafeStart.PAUSED,runCatching { LocalSpeech(native,paused).transcribe(samples,file,m,emptyList(),"en") }.exceptionOrNull()?.message)
            assertEquals("a paused model never reaches native code",1,calls)
            assertTrue(paused.tryOnce(m,file,native)); assertFalse(paused.paused(m))
            assertEquals("hello",LocalSpeech(native,paused).transcribe(samples,file,m,emptyList(),"en"))
        }
    }
}
