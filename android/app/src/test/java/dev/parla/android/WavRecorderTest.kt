package dev.parla.android

import java.nio.ByteBuffer
import java.nio.ByteOrder
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class WavRecorderTest {
    @Test fun pcmHeaderDescribesMono16BitAudioAndExactPayload() {
        val header = WavHeader.create(32_000)
        val buffer = ByteBuffer.wrap(header).order(ByteOrder.LITTLE_ENDIAN)
        assertEquals(44, header.size)
        assertEquals("RIFF", String(header, 0, 4, Charsets.US_ASCII))
        assertEquals(32_036, buffer.getInt(4))
        assertEquals("WAVEfmt ", String(header, 8, 8, Charsets.US_ASCII))
        assertEquals(16, buffer.getInt(16))
        assertEquals(1, buffer.getShort(20).toInt())
        assertEquals(1, buffer.getShort(22).toInt())
        assertEquals(16_000, buffer.getInt(24))
        assertEquals(32_000, buffer.getInt(28))
        assertEquals(2, buffer.getShort(32).toInt())
        assertEquals(16, buffer.getShort(34).toInt())
        assertEquals("data", String(header, 36, 4, Charsets.US_ASCII))
        assertEquals(32_000, buffer.getInt(40))
    }

    @Test fun emptyAndMaximumSessionRemainValidAndBelowUploadLimit() {
        assertEquals(36, ByteBuffer.wrap(WavHeader.create(0)).order(ByteOrder.LITTLE_ENDIAN).getInt(4))
        val maximum = WavRecorder.MAX_DATA_BYTES
        assertEquals(9_600_000L, maximum)
        assertEquals(maximum.toInt(), ByteBuffer.wrap(WavHeader.create(maximum)).order(ByteOrder.LITTLE_ENDIAN).getInt(40))
        assertTrue(maximum + 44 < 25_000_000)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsPartialPcmSamples() { WavHeader.create(3) }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsRiffOverflow() { WavHeader.create(0x1_0000_0000L) }
}
