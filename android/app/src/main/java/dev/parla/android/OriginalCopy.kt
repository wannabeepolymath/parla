package dev.parla.android

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

/**
 * Desktop OriginalCopyController: the last dictation's original words, in RAM only, until 30 seconds after the
 * write was dispatched. Independent of history and of RecoveryVault (failure recovery). Reading never renews it,
 * and any clear() between dispatch and completion (new capture, setting off, form, microphone test) wins.
 */
internal class OriginalCopyOwner(private val now: () -> Long, private val schedule: (Long, () -> Unit) -> () -> Unit = ::onMainAfter) {
    /** Scalar projection only: never the text itself. */
    data class Offer(val token: Long, val expiresAt: Long)
    class Attempt internal constructor(internal val epoch: Long, internal val dispatchedAt: Long)
    private var epoch = 0L
    private var original: String? = null
    private val mutable = MutableStateFlow<Offer?>(null)
    val offer = mutable.asStateFlow()
    private var cancelExpiry: (() -> Unit)? = null
    /** False while the screen is off: nothing is retained then, since the uptime timer can't count deep sleep. */
    @Volatile var interactive = true

    @Synchronized fun clear() { epoch++; original = null; mutable.value = null; cancelExpiry?.invoke(); cancelExpiry = null }
    /** At the moment the write is authorized. Also invalidates any earlier original. */
    @Synchronized fun dispatched(): Attempt { clear(); return Attempt(epoch,now()) }
    /** After the write returned. Keeps [raw] until dispatch + 30 s unless something cleared since dispatch. */
    @Synchronized fun completed(attempt: Attempt, raw: String): Boolean {
        val expires = attempt.dispatchedAt+LIFETIME_MS
        if(!interactive || attempt.epoch != epoch || raw.isEmpty() || now() !in attempt.dispatchedAt until expires) return false
        original = raw; mutable.value = Offer(epoch,expires)
        // Expiry must not depend on a screen being composed. The epoch keeps an older timer off a newer original.
        val kept = epoch
        cancelExpiry?.invoke(); cancelExpiry = schedule(expires-now()) { synchronized(this) { if(epoch == kept) clear() } }
        return true
    }
    @Synchronized fun refresh(): Offer? {
        mutable.value?.let { if(now() !in (it.expiresAt-LIFETIME_MS) until it.expiresAt) clear() }
        return mutable.value
    }
    /**
     * The timer runs on uptime, which stops in deep sleep while the deadline (elapsedRealtime) doesn't. Deep sleep
     * only follows screen-off, so screen-off clears; screen-on/unlock re-checks the deadline as a backstop.
     */
    fun screenChanged(off: Boolean) { interactive = !off; if(off) clear() else refresh() }
    /** Explicit Copy original. Repeated copies are allowed until the original deadline. */
    @Synchronized fun copy(token: Long): String? = if(refresh()?.token == token) original else null
    companion object { const val LIFETIME_MS = 30_000L }
}

private fun onMainAfter(delayMs: Long, action: () -> Unit): () -> Unit {
    val handler = Handler(Looper.getMainLooper()); val run = Runnable(action)
    handler.postDelayed(run,delayMs)
    return { handler.removeCallbacks(run) }
}

internal val OriginalCopy = OriginalCopyOwner(SystemClock::elapsedRealtime)

/** Home: shown only while an original is available. */
@Composable internal fun OriginalCopyOffer(offer: OriginalCopyOwner.Offer, onCopy: (String) -> Unit) {
    LaunchedEffect(offer) { delay((offer.expiresAt-SystemClock.elapsedRealtime()).coerceAtLeast(0)); OriginalCopy.refresh() }
    Row(Modifier.fillMaxWidth(),verticalAlignment = Alignment.CenterVertically) {
        Text("Original text of your last dictation is available for a few seconds.",Modifier.weight(1f),style = MaterialTheme.typography.bodySmall)
        TextButton(onClick = { OriginalCopy.copy(offer.token)?.let(onCopy) }) { Text("Copy original") }
    }
}

/** Privacy: the preference and the explicit action. Turning it off clears the original immediately. */
@Composable internal fun OriginalCopySettings(settings: Settings, onSettings: (Settings) -> Unit, onCopy: (String) -> Unit) {
    val offer by OriginalCopy.offer.collectAsState()
    LaunchedEffect(offer) { offer?.let { delay((it.expiresAt-SystemClock.elapsedRealtime()).coerceAtLeast(0)); OriginalCopy.refresh() } }
    Column {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text("Keep original text briefly",Modifier.weight(1f))
            Switch(settings.keepLastOriginal,{ on -> if(!on) OriginalCopy.clear(); onSettings(settings.copy(keepLastOriginal = on)) })
        }
        Text("Keeps your last dictation's original text in memory for 30 seconds, even with history off. Never saved. Private fields are skipped.",style = MaterialTheme.typography.bodySmall)
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(when { !settings.keepLastOriginal -> "Turned off"; offer == null -> "Nothing to copy right now"; else -> "Available for a few seconds" },Modifier.weight(1f),style = MaterialTheme.typography.bodySmall)
            TextButton(onClick = { offer?.let { OriginalCopy.copy(it.token) }?.let(onCopy) },enabled = settings.keepLastOriginal && offer != null) { Text("Copy original") }
        }
    }
}
