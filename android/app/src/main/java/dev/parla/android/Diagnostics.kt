package dev.parla.android

import android.content.Intent
import android.util.Log
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import java.time.Instant
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

// Privacy: every field is an enum or a number, so dictated text, field text, keys and app names cannot be recorded.
// Inside transcription: model_verify (Kotlin SHA/header check, ~0 when trusted), model_load (native init), whisper_decode
// (native whisper_full). import_start opens a file-import session; file_decode is its audio decoding.
internal enum class TimingStage { record_start, record_stop, transcription_start, transcription_end, cleanup_start, cleanup_end, insertion,
    model_verify, model_load, whisper_decode, import_start, file_decode }
internal enum class TimingOutcome { ok, failed, canceled, mic_silenced, fallback, unconfirmed }
internal enum class ProviderCategory {
    local, anthropic, openai, groq, gemini, openrouter, custom, openai_compatible, other;
    companion object { fun of(provider: String) = when (provider) {
        "anthropic" -> anthropic; "openai" -> openai; "groq" -> groq; "gemini" -> gemini; "openrouter" -> openrouter
        "custom" -> custom; "openai-compatible" -> openai_compatible; else -> other } }
}

internal data class TimingEvent(
    val wallMs: Long, val session: Int, val stage: TimingStage, val atMs: Long,
    val durationMs: Long? = null, val outcome: TimingOutcome = TimingOutcome.ok, val provider: ProviderCategory? = null,
) {
    fun format(): String = buildString {
        append(Instant.ofEpochMilli(wallMs)).append(" #").append(session).append(' ').append(stage.name).append(" +").append(atMs).append("ms")
        durationMs?.let { append(" dur=").append(it).append("ms") }
        append(' ').append(outcome.name)
        provider?.let { append(" provider=").append(it.name) }
    }
}

/** One dictation's clock. Offsets are from the session start. */
internal class TimingSession(
    private val sink: (TimingEvent) -> Unit = Diagnostics::record,
    private val clock: () -> Long = { System.nanoTime() / 1_000_000 },
    private val wall: () -> Long = System::currentTimeMillis,
) {
    private val id = Diagnostics.nextSession()
    private val origin = clock()

    fun mark(stage: TimingStage, since: Long? = null, outcome: TimingOutcome = TimingOutcome.ok, provider: ProviderCategory? = null): Long {
        val now = clock()
        sink(TimingEvent(wall(), id, stage, now - origin, since?.let { now - it }, outcome, provider))
        return now
    }

    /** Logs [start] (when given) and [end] with the duration, including failure and cancellation. */
    inline fun <T> span(start: TimingStage?, end: TimingStage, provider: () -> ProviderCategory? = { null },
                        finish: (T) -> TimingOutcome = { TimingOutcome.ok }, block: () -> T): T {
        val begun = if (start != null) mark(start) else now()
        val value = try { block() } catch (error: Throwable) {
            val outcome = when (error) {
                is CancellationException -> TimingOutcome.canceled
                is MicrophoneSilencedException -> TimingOutcome.mic_silenced
                else -> TimingOutcome.failed
            }
            mark(end, begun, outcome, provider()); throw error
        }
        mark(end, begun, finish(value), provider())
        return value
    }
    fun now(): Long = clock()
    /** A duration measured elsewhere (native code). */
    fun duration(stage: TimingStage, ms: Long) { sink(TimingEvent(wall(), id, stage, clock() - origin, ms)) }
}

/** Kept in memory until parla closes, bounded, and mirrored to logcat under [TAG]. Nothing is uploaded. */
internal object Diagnostics {
    const val TAG = "ParlaTiming"
    private const val LIMIT = 300
    private val sessions = AtomicInteger()
    private val mutable = MutableStateFlow<List<TimingEvent>>(emptyList())
    val events = mutable.asStateFlow()
    fun nextSession() = sessions.incrementAndGet()
    fun record(event: TimingEvent) {
        mutable.update { (it + event).takeLast(LIMIT) }
        Log.i(TAG, event.format())
    }
    fun clear() { mutable.value = emptyList() }
    fun export(events: List<TimingEvent>) = (listOf("parla diagnostics · timings and outcomes only") + events.map(TimingEvent::format)).joinToString("\n")
}

@Composable internal fun DiagnosticsScreen() {
    val context = LocalContext.current
    val events by Diagnostics.events.collectAsStateWithLifecycle()
    Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
        Text("Timings and outcomes only. No text, audio, keys or app names. Kept on this device until parla closes.")
        Row {
            TextButton(onClick = {
                val intent = Intent(Intent.ACTION_SEND).setType("text/plain").putExtra(Intent.EXTRA_TEXT, Diagnostics.export(events))
                context.startActivity(Intent.createChooser(intent, "Export diagnostics"))
            }, enabled = events.isNotEmpty()) { Text("Export") }
            TextButton(onClick = Diagnostics::clear, enabled = events.isNotEmpty()) { Text("Clear", color = MaterialTheme.colorScheme.error) }
        }
        if (events.isEmpty()) Text("Nothing recorded yet. Dictate once to see timings here.")
        LazyColumn(Modifier.fillMaxWidth().weight(1f)) {
            items(events.asReversed()) { Text(it.format(), fontFamily = FontFamily.Monospace, fontSize = 11.sp, lineHeight = 16.sp) }
        }
    }
}
