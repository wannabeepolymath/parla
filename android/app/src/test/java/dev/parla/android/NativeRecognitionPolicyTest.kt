package dev.parla.android

import java.io.File
import org.junit.Assert.*
import org.junit.Test

/** Source checks for the JNI bridge: both live dictation and file import go through the same decode. */
class NativeRecognitionPolicyTest {
    private val bridge = File("../native/bridge.cpp").readText()

    @Test fun everyDecodePastOneWindowUsesTimestampSeeking() {
        // F3: untimed decode skipped the rest of a 30 s window; bridge_policy_test.cpp checks decode_timestamps itself.
        assertTrue(bridge.contains("p.no_timestamps = !parla::decode_timestamps(timed, count);"))
        assertEquals(1, Regex("""no_timestamps\s*=""").findAll(bridge).count())
    }

    @Test fun bridgeTriesEveryAndroidCpuVariantGgmlBuildsBestFirst() {
        val cmake = File("../native/vendor/whisper/ggml/src/CMakeLists.txt").readText()
        val built = Regex("""ggml_add_cpu_backend_variant\((android_[\w.]+)""").findAll(cmake).map { it.groupValues[1] }.toList()
        val loaded = Regex(""""(android_[\w.]+)"""").findAll(bridge).map { it.groupValues[1] }.toList()
        assertEquals(built.toSet(), loaded.toSet())
        assertEquals("android_armv8.0_1", loaded.last()) // the baseline every arm64 phone can run
        assertFalse(bridge.contains("flash_attn = false"))
    }
}
