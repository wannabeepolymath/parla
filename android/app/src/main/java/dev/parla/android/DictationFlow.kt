package dev.parla.android

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive

/** Production session policy, independent of Android microphone/editor adapters. */
internal class DictationFlow(private val pipeline: Pipeline = Pipeline()) {
    suspend fun run(
        operation: PendingOperation,
        frozen: LocalData,
        category: AppCategory,
        singleLine: Boolean,
        duration: Long,
        transcribe: suspend () -> String,
        key: () -> String,
        save: (HistoryEntry, Boolean) -> Boolean,
        deliver: suspend (String, () -> Boolean) -> String,
        stage: (PendingOperation.Stage, String) -> Unit,
    ): HistoryEntry {
        suspend fun active() { currentCoroutineContext().ensureActive(); if(operation.revoked) throw CancellationException("Operation revoked") }
        fun advance(next: PendingOperation.Stage, message: String) { operation.advance(next); stage(next,message) }
        var prepared: HistoryEntry? = null
        var saved = false
        try {
            active(); advance(PendingOperation.Stage.recognizing,"Transcribing on device…")
            val raw = transcribe()
            active(); advance(PendingOperation.Stage.cleaning,"Preparing your text…")
            val result = pipeline.clean(raw,frozen,category,singleLine,key)
            active(); advance(PendingOperation.Stage.ready,"Text ready · checking the text field…")
            val text = TextRules.shape(result.text,category,singleLine)
            // Persist a conservative outcome first: later disk failures must never leave a durable no-write claim.
            val entry = HistoryEntry(raw = raw,text = text,note = listOfNotNull(result.warning,"Text insertion is unconfirmed. Check the field before pasting.").joinToString(" · "),durationMs = duration)
            prepared = entry; operation.prepared = entry
            val retained = RecoveryVault.retain(operation.id,raw,text,"Text ready. Nothing inserted yet.")
            saved = frozen.settings.noHistory || save(entry,false)
            active()
            val insertion = deliver(text) {
                if(!operation.authorizeDispatch()) false else {
                    val uncertain = "Text may have been inserted. Check the field before pasting."
                    RecoveryVault.outcome(operation.id,uncertain)
                    if(!frozen.settings.noHistory && saved) save(entry.copy(note = listOfNotNull(result.warning,uncertain).joinToString(" · ")),true)
                    stage(PendingOperation.Stage.delivering,"Inserting your text…")
                    true
                }
            }
            active()
            val note = listOfNotNull(result.warning,insertion,if(!saved) "History was not saved" else null,if(!retained) "Text is too long for temporary recovery" else null).joinToString(" · ")
            val finished = entry.copy(note = note)
            RecoveryVault.outcome(operation.id,note)
            if(!frozen.settings.noHistory && saved) save(finished,true)
            advance(PendingOperation.Stage.finished,note)
            return finished
        } catch(c: CancellationException) {
            prepared?.let { entry ->
                val note = cancellationMessage(operation.writeIssued)
                RecoveryVault.outcome(operation.id,note)
                if(!frozen.settings.noHistory && saved) save(entry.copy(note = note),true)
            }
            throw c
        }
    }
    companion object {
        fun cancellationMessage(attempted: Boolean) = if(attempted) "Canceled. Text may have been inserted; check the field before pasting. Result kept."
            else "Canceled before inserting text. Any ready result is available in recovery."
    }
}
