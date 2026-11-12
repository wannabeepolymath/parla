package dev.parla.android

import java.util.UUID
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow

internal class PendingOperation {
    enum class Stage { acquiring, recording, recognizing, cleaning, ready, delivering, finished, discarded }
    val id = UUID.randomUUID().toString()
    @Volatile var prepared: HistoryEntry? = null
    @Volatile var revoked = false; private set
    @Volatile var writeIssued = false; private set
    @Volatile var stage = Stage.acquiring; private set
    @Synchronized fun advance(next: Stage) { if(!revoked) stage = next }
    @Synchronized fun authorizeDispatch(): Boolean {
        if(revoked || writeIssued) return false
        writeIssued = true; stage = Stage.delivering; return true
    }
    @Synchronized fun revoke(): Boolean { revoked = true; stage = Stage.discarded; return writeIssued }
}
internal data class RecoveryResult(val operationID: String, val original: String, val result: String, val outcome: String, val expiresAt: Long)
/** One process-local result, maximum 64KiB for both texts, expires after five minutes. No persistence. */
internal object RecoveryVault {
    private val mutable = MutableStateFlow<RecoveryResult?>(null)
    val value = mutable.asStateFlow()
    private val scope = CoroutineScope(SupervisorJob()+Dispatchers.Default)
    private var expiry: Job? = null
    @Synchronized fun retain(id: String, original: String, result: String, outcome: String, now: Long = System.currentTimeMillis()): Boolean {
        expiry?.cancel()
        if(original.toByteArray().size + result.toByteArray().size > 64*1024) { mutable.value = null; return false }
        val record = RecoveryResult(id,original,result,outcome,now+300000)
        mutable.value = record
        expiry = scope.launch { delay(300000); synchronized(this@RecoveryVault) { if(mutable.value?.operationID == id) mutable.value = null } }
        return true
    }
    @Synchronized fun outcome(id: String, message: String) { mutable.value?.takeIf { it.operationID == id }?.let { mutable.value = it.copy(outcome = message) } }
    @Synchronized fun clear() { expiry?.cancel(); mutable.value = null }
    fun current(now: Long = System.currentTimeMillis()) = mutable.value?.takeIf { it.expiresAt > now }
}
internal data class RetryProposal(val token: String, val source: HistoryEntry, val result: String, val summary: String)
internal class HistoryRetry {
    private val owners = mutableMapOf<String,String>()
    @Synchronized fun begin(row: HistoryEntry): String = UUID.randomUUID().toString().also { owners[row.id] = it }
    @Synchronized fun invalidate(id: String) { owners.remove(id) }
    @Synchronized fun clear() { owners.clear() }
    @Synchronized fun valid(token: String, source: HistoryEntry, rows: List<HistoryEntry>) = owners[source.id] == token && rows.any { it == source }
    suspend fun propose(token: String, source: HistoryEntry, frozen: LocalData, key: () -> String, applyPreset: Boolean = false, pipeline: Pipeline = Pipeline()): RetryProposal {
        require(source.raw.isNotEmpty()) { "There is no original text to retry." }
        val settings = frozen.settings.copy(outputMode = if(applyPreset) "selectedPreset" else "cleanup")
        val result = pipeline.clean(source.raw,frozen.copy(settings = settings),key = key)
        require(result.warning == null) { result.warning.orEmpty() }
        return RetryProposal(token,source,result.text,"Uses your current settings for general text. Nothing inserted into an app. Style: ${styleLabel(settings.style)}." )
    }
}
internal fun exportHistory(rows: List<HistoryEntry>, markdown: Boolean): String = rows.joinToString("\n\n") { row ->
    if(markdown) "## ${java.util.Date(row.createdAt)}\n\n${row.text}\n\n### Original\n\n${row.raw}\n\n${row.note}"
    else "${java.util.Date(row.createdAt)}\n${row.text}\nOriginal:\n${row.raw}\n${row.note}"
}
