package dev.parla.android

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Production session policy, independent of Android microphone/editor adapters. */
internal class DictationFlow(private val pipeline: Pipeline = Pipeline(), private val clock: () -> Long = System::nanoTime, private val originals: OriginalCopyOwner = OriginalCopy) {
    suspend fun run(
        operation: PendingOperation,
        frozen: LocalData,
        category: AppCategory,
        singleLine: Boolean,
        duration: Long,
        transcribe: suspend () -> String,
        key: (String) -> String,
        save: (HistoryEntry, Boolean) -> Boolean,
        deliver: suspend (String, () -> Boolean) -> String,
        stage: (PendingOperation.Stage, String) -> Unit,
        timing: TimingSession = TimingSession(sink = {}),
        /** Live saved data: enables reviewed backup cleanup for this ordinary dictation. */
        failover: kotlinx.coroutines.flow.StateFlow<LocalData>? = null,
        app: String = "",
        /** Reviewed nearby text for this capture; its result is for insertion only. */
        nearby: NearbyContext? = null,
        /** Selected-text change of the recognized source. A failed change writes nothing. */
        transform: (suspend (String, (String) -> String) -> CleanupResult)? = null,
    ): HistoryEntry {
        val begun = clock()
        suspend fun active() { currentCoroutineContext().ensureActive(); if(operation.revoked) throw CancellationException("Operation revoked") }
        fun advance(next: PendingOperation.Stage, message: String) { operation.advance(next); stage(next,message) }
        var prepared: HistoryEntry? = null
        var saved = false
        try {
            active(); advance(PendingOperation.Stage.recognizing,"Transcribing on device…")
            val raw = timing.span(TimingStage.transcription_start,TimingStage.transcription_end) { transcribe() }
            active(); advance(PendingOperation.Stage.cleaning,"Preparing your text…")
            // The pipeline reads a key only when it calls a provider, so that marks a network cleanup.
            var networked = false
            val result = timing.span(TimingStage.cleanup_start,TimingStage.cleanup_end,
                provider = { if(networked) ProviderCategory.of(frozen.settings.provider) else ProviderCategory.local },
                finish = { if(it.warning != null) TimingOutcome.fallback else TimingOutcome.ok }) {
                val networkKey = { scope: String -> networked = true; key(scope) }
                transform?.invoke(raw,networkKey) ?: pipeline.clean(raw,frozen,category,singleLine,failover = failover,nearby = nearby,key = networkKey)
            }
            active()
            if(transform != null && result.warning != null) {
                val failed = HistoryEntry(raw = raw,text = raw,note = result.warning,durationMs = duration,app = app,model = frozen.settings.localModel,latencyMs = (clock()-begun)/1_000_000)
                // Same storage-only retry as ordinary dictation. Private fields freeze noHistory, so never reach history.
                val unsaved = !frozen.settings.noHistory && !save(failed,false)
                if(unsaved) PendingHistory.put(failed)
                val note = listOfNotNull(result.warning,if(unsaved) "History was not saved" else null).joinToString(" · ")
                advance(PendingOperation.Stage.finished,note)
                return failed.copy(note = note)
            }
            advance(PendingOperation.Stage.ready,"Text ready · checking the text field…")
            val text = TextRules.shape(result.text,category,singleLine)
            // Mac raw-history/no-retrieval: a result shaped by nearby text is never kept, only inserted.
            val kept = if(result.contextual) raw else text
            // Persist a conservative outcome first: later disk failures must never leave a durable no-write claim.
            val entry = HistoryEntry(raw = raw,text = kept,note = listOfNotNull(result.warning,"Text insertion is unconfirmed. Check the field before pasting.").joinToString(" · "),durationMs = duration,
                app = app,model = frozen.settings.localModel,latencyMs = (clock()-begun)/1_000_000,
                cleanupModel = result.usage?.model.orEmpty(),inputTokens = result.usage?.input,outputTokens = result.usage?.output)
            prepared = entry; operation.prepared = entry
            val retained = RecoveryVault.retain(operation.id,raw,kept,"Text ready. Nothing inserted yet.")
            saved = frozen.settings.noHistory || save(entry,false)
            // Mac pendingHistory: an unsaved row stays in memory for an explicit, storage-only retry.
            if(!saved) PendingHistory.put(entry)
            active()
            // Capture-time opt-in, like desktop permitsOriginalCopy: ordinary dictation only, not a preset transform.
            val keepOriginal = transform == null && frozen.settings.keepLastOriginal && frozen.settings.outputMode != "selectedPreset"
            var original: OriginalCopyOwner.Attempt? = null
            val insertion = timing.span(null,TimingStage.insertion,finish = { if(it == INSERTED) TimingOutcome.ok else TimingOutcome.unconfirmed }) { deliver(text) {
                if(!operation.authorizeDispatch()) false else {
                    if(keepOriginal) original = originals.dispatched() else originals.clear()
                    val uncertain = "Text may have been inserted. Check the field before pasting."
                    RecoveryVault.outcome(operation.id,uncertain)
                    if(!frozen.settings.noHistory && saved) save(entry.copy(note = listOfNotNull(result.warning,uncertain).joinToString(" · ")),true)
                    stage(PendingOperation.Stage.delivering,"Inserting your text…")
                    true
                }
            } }
            active()
            original?.let { originals.completed(it,raw) }
            val note = listOfNotNull(result.warning,insertion,if(!saved) "History was not saved" else null,if(!retained) "Text is too long for temporary recovery" else null).joinToString(" · ")
            val finished = entry.copy(note = note)
            RecoveryVault.outcome(operation.id,note)
            if(!frozen.settings.noHistory && saved) save(finished,true)
            if(!saved) PendingHistory.put(entry.copy(note = listOfNotNull(result.warning,insertion).joinToString(" · ")))
            advance(PendingOperation.Stage.finished,note)
            return finished
        } catch(c: CancellationException) {
            prepared?.let { entry ->
                val note = cancellationMessage(operation.writeIssued)
                RecoveryVault.outcome(operation.id,note)
                if(!frozen.settings.noHistory && saved) save(entry.copy(note = note),true)
                if(!saved) PendingHistory.put(entry.copy(note = note))
            }
            throw c
        }
    }
    companion object {
        /** The only outcome ParlaAccessibilityService.insert returns after a verified write. */
        const val INSERTED = "Text inserted."
        fun cancellationMessage(attempted: Boolean) = if(attempted) "Canceled. Text may have been inserted; check the field before pasting. Result kept."
            else "Canceled before inserting text. Any ready result is available in recovery."
    }
}
