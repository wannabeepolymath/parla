package dev.parla.android

import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.sin
import kotlin.math.sqrt
import kotlinx.coroutines.*
import org.junit.Assert.*
import org.junit.Test

class AudioImportTest {
    private fun resample(input: FloatArray, rate: Int): FloatArray {
        val sink = PcmSink(Int.MAX_VALUE / 2, 1024)
        Resampler(rate, sink).apply { input.forEach(::push); finish() }
        return sink.toArray()
    }
    private fun tone(hz: Double, rate: Int, seconds: Double, amplitude: Double = 0.5) = FloatArray((rate * seconds).toInt()) { (amplitude * sin(2 * PI * hz * it / rate)).toFloat() }
    private fun rms(x: FloatArray, from: Int, to: Int): Double { var s = 0.0; for(i in from until to) s += x[i].toDouble() * x[i]; return sqrt(s / (to - from)) }

    @Test fun sixteenKilohertzPassesThroughUnchanged() {
        val input = tone(440.0, 16_000, 0.25)
        assertArrayEquals(input, resample(input, 16_000), 0f)
    }

    @Test fun outputLengthIsCeilOfDurationAtSixteenKilohertz() {
        for((rate, n) in listOf(48_000 to 48_000, 44_100 to 44_100, 22_050 to 1_001, 8_000 to 8_000, 11_025 to 5_000))
            assertEquals("rate $rate", ((n.toLong() * 16_000 + rate - 1) / rate).toInt(), resample(FloatArray(n), rate).size)
    }

    @Test fun constantSignalKeepsUnityGainAwayFromEdges() {
        for(rate in listOf(8_000, 22_050, 44_100, 48_000)) {
            val out = resample(FloatArray(rate) { 0.5f }, rate)
            for(i in 200 until out.size - 200) assertEquals("rate $rate at $i", 0.5f, out[i], 1e-3f)
        }
    }

    @Test fun inBandToneIsPreservedInPhaseAndLevel() {
        for(rate in listOf(44_100, 48_000, 8_000)) {
            val out = resample(tone(1_000.0, rate, 0.5), rate)
            val expected = tone(1_000.0, 16_000, 0.5)
            var worst = 0f
            for(i in 400 until out.size - 400) worst = maxOf(worst, abs(out[i] - expected[i]))
            assertTrue("rate $rate error $worst", worst < 0.01f)
        }
    }

    @Test fun contentAboveTheNewNyquistIsFilteredInsteadOfAliased() {
        // 12 kHz would alias to 4 kHz at 16 kHz without the low-pass.
        val out = resample(tone(12_000.0, 48_000, 0.5), 48_000)
        assertTrue(rms(out, 400, out.size - 400) < 0.005)
    }

    @Test fun canceledCopyNeverLeavesAPrivateFileBehind() = kotlinx.coroutines.runBlocking {
        val dir = java.nio.file.Files.createTempDirectory("parla-import").toFile()
        try {
            // Cancellation during the copy loop removes the partial copy.
            val partial = dir.resolve("import-a"); var reads = 0
            val input = object : java.io.InputStream() {
                override fun read() = 0
                override fun read(b: ByteArray, off: Int, len: Int): Int { reads++; return len }
            }
            assertTrue(runCatching { copyBounded(input, partial) { reads >= 2 } }.exceptionOrNull() is kotlinx.coroutines.CancellationException)
            assertFalse(partial.exists())
            // A finished copy whose result is discarded at the dispatcher handoff is deleted too.
            val done = dir.resolve("import-b"); val entered = java.util.concurrent.CountDownLatch(1); val finish = java.util.concurrent.CountDownLatch(1)
            var published = false
            val job = launch {
                stagePrivateCopy(done, { kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                    done.writeText("audio"); entered.countDown(); finish.await(); ImportSource("a.wav", 5, done)
                } }) { published = true }
            }
            kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) { entered.await() }
            job.cancel(); finish.countDown(); job.join()
            assertFalse(published); assertFalse(done.exists())
            // The normal path publishes and keeps the file.
            val kept = dir.resolve("import-c")
            stagePrivateCopy(kept, { kept.writeText("audio"); ImportSource("c.wav", 5, kept) }) { published = true }
            assertTrue(published); assertTrue(kept.exists())
        } finally { dir.deleteRecursively() }
    }

    @Test fun sinkClampsRefusesNonFiniteAndEnforcesTheDurationCeiling() {
        val sink = PcmSink(3, 1)
        sink.add(2f); sink.add(-2f); sink.add(0.25f)
        assertArrayEquals(floatArrayOf(1f, -1f, 0.25f), sink.toArray(), 0f)
        assertEquals(AudioFileDecoder.TOO_LONG, runCatching { sink.add(0f) }.exceptionOrNull()?.message)
        assertEquals(AudioFileDecoder.UNREADABLE, runCatching { PcmSink(4).add(Float.NaN) }.exceptionOrNull()?.message)
        assertTrue(runCatching { Resampler(1_000, PcmSink(4)) }.isFailure)
        assertEquals(0.25f, downmix(floatArrayOf(0.5f, 0f), 2), 0f)
        assertEquals(-0.5f, downmix(floatArrayOf(-0.5f), 1), 0f)
    }
}
