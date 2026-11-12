package dev.parla.android

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import java.io.File
import java.io.RandomAccessFile
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import kotlin.math.sqrt

/** A single recording session. Create a new instance after stop or cancellation. */
class WavRecorder(context: Context) {
    private val appContext = context.applicationContext
    private val stopped = AtomicBoolean(false)
    private val used = AtomicBoolean(false)

    /** Persist stop intent even if the recording coroutine has not started yet. */
    fun stop() { stopped.set(true) }

    @SuppressLint("MissingPermission") // Checked immediately before constructing AudioRecord.
    suspend fun record(file: File, onLevel: (Float) -> Unit): Unit = withContext(Dispatchers.IO) {
        check(used.compareAndSet(false, true)) { "Start a new recording session to try again." }
        check(!stopped.get()) { "Recording stopped before it began. Tap the parla voice control to try again." }
        check(appContext.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            "Microphone access is off. Allow it in parla's permissions and try again."
        }
        val privatePath = file.canonicalPath
        check(listOf(appContext.cacheDir, appContext.filesDir).any {
            privatePath.startsWith(it.canonicalPath + File.separator)
        }) { "Audio must be recorded in parla's private storage." }
        val minimum = AudioRecord.getMinBufferSize(SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO, AudioFormat.ENCODING_PCM_16BIT)
        check(minimum > 0) { "This device cannot record in the required audio format. Check your microphone and try again." }
        val bufferBytes = maxOf(minimum * 2, 4096)
        var microphone: AudioRecord? = null
        var output: RandomAccessFile? = null
        var dataBytes = 0L
        var complete = false
        try {
            currentCoroutineContext().ensureActive()
            check(!stopped.get()) { "Recording stopped before it began. Tap the parla voice control to try again." }
            microphone = AudioRecord(
                MediaRecorder.AudioSource.MIC, SAMPLE_RATE, AudioFormat.CHANNEL_IN_MONO,
                AudioFormat.ENCODING_PCM_16BIT, bufferBytes,
            )
            check(microphone.state == AudioRecord.STATE_INITIALIZED) {
                "The microphone is unavailable. Close other recording apps and try again."
            }
            output = RandomAccessFile(file, "rw").apply { setLength(0); write(WavHeader.create(0)) }
            currentCoroutineContext().ensureActive()
            check(!stopped.get()) { "Recording stopped before it began. Tap the parla voice control to try again." }
            microphone.startRecording()
            check(microphone.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                "Recording could not start. Check microphone access and try again."
            }
            val deadline = System.nanoTime() + MAX_SECONDS * 1_000_000_000L
            val samples = ShortArray(bufferBytes / 2)
            val bytes = ByteArray(bufferBytes)
            while (!stopped.get() && dataBytes < MAX_DATA_BYTES && System.nanoTime() < deadline) {
                currentCoroutineContext().ensureActive()
                val requestedSamples = minOf(samples.size.toLong(), (MAX_DATA_BYTES - dataBytes) / 2).toInt()
                val count = microphone.read(samples, 0, requestedSamples, AudioRecord.READ_NON_BLOCKING)
                check(count >= 0) { "The microphone disconnected. Check your audio device and try again." }
                if (count == 0) {
                    delay(10)
                    continue
                }
                var sumSquares = 0.0
                for (index in 0 until count) {
                    val sample = samples[index].toInt()
                    bytes[index * 2] = sample.toByte()
                    bytes[index * 2 + 1] = (sample shr 8).toByte()
                    sumSquares += sample.toDouble() * sample
                }
                output.write(bytes, 0, count * 2)
                dataBytes += count * 2
                onLevel((sqrt(sumSquares / count) / 32768.0).toFloat().coerceIn(0f, 1f))
            }
            currentCoroutineContext().ensureActive()
            check(dataBytes > 0) { "No audio was captured. Speak a little longer and try again." }
            complete = true
        } finally {
            microphone?.let { recorder ->
                runCatching { if (recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) recorder.stop() }
                runCatching { recorder.release() }
            }
            try {
                output?.let { writer ->
                    try {
                        writer.seek(0)
                        writer.write(WavHeader.create(dataBytes))
                    } finally { writer.close() }
                }
            } catch (error: Throwable) {
                complete = false
                throw error
            } finally {
                if (!complete) file.delete()
            }
        }
    }

    companion object {
        const val SAMPLE_RATE = 16_000
        const val MAX_SECONDS = 300
        const val MAX_DATA_BYTES = SAMPLE_RATE.toLong() * 2 * MAX_SECONDS
    }
}

internal object WavHeader {
    fun create(dataBytes: Long, sampleRate: Int = WavRecorder.SAMPLE_RATE): ByteArray {
        require(dataBytes in 0..(0xffff_ffffL - 36) && dataBytes % 2 == 0L)
        require(sampleRate in 1..(Int.MAX_VALUE / 2))
        return ByteBuffer.allocate(44).order(ByteOrder.LITTLE_ENDIAN).apply {
            put("RIFF".toByteArray(Charsets.US_ASCII)); putInt((36 + dataBytes).toInt())
            put("WAVEfmt ".toByteArray(Charsets.US_ASCII)); putInt(16)
            putShort(1); putShort(1); putInt(sampleRate); putInt(sampleRate * 2)
            putShort(2); putShort(16); put("data".toByteArray(Charsets.US_ASCII)); putInt(dataBytes.toInt())
        }.array()
    }
}
