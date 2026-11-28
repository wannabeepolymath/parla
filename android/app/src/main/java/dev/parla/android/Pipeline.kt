package dev.parla.android

import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** Frozen output settings; neither editor text nor package identifiers leave the device. */
class Pipeline(private val api: ApiClient = ApiClient(), private val clock: () -> Long = { System.nanoTime() / 1_000_000 }) {
    /**
     * [key] receives a credential scope and must return only the key saved for that scope.
     * [failover] is the live saved data, passed only by ordinary dictation; history retries and presets
     * never use backups. Each backup is re-authorized against it before sending and while in flight.
     */
    suspend fun clean(raw: String, data: LocalData, category: AppCategory = AppCategory.unknown, singleLine: Boolean = false, failover: StateFlow<LocalData>? = null, key: (String) -> String): CleanupResult {
        val s = data.settings
        if(s.outputMode == "raw") return CleanupResult(raw)
        if(s.outputMode != "selectedPreset") {
            TextRules.snippetExpansion(raw, data.snippets)?.let { return CleanupResult(it) }
            if(!s.cleanupEnabled) return CleanupResult(TextRules.replace(raw, data.replacements))
        }
        return try {
            val transform = s.outputMode == "selectedPreset"
            val instruction = if(transform) {
                outputCheck(raw.isNotEmpty(), "There is no text to change")
                outputCheck(s.cleanupEnabled, "Turn on AI cleanup in Output settings to use a preset")
                val matches = data.presets.filter { it.id == s.selectedPresetID }
                outputCheck(matches.size == 1, "Choose a saved preset in Output settings.")
                val preset = matches.single()
                try { preset.validate() } catch (_: IllegalArgumentException) {
                    throw ApiFailure("The selected preset is invalid. Edit it in Output settings.")
                }
                preset.intent
            } else null
            fun keyFor(scope: String) = try { key(scope) } catch(c: CancellationException) { throw c } catch(e: IllegalStateException) {
                // Store's own fixed messages (paused data, Keystore failure); never provider text.
                throw ApiFailure(e.message ?: "Your saved key couldn't be read. Save it again in API connection.", ApiFailure.Kind.setup)
            }
            val primary = s.endpoint()
            val output = if(failover != null && !transform && CleanupFailover.isReviewed(s)) {
                val chain = listOf(primary) + s.backups.map { it.endpoint() }
                // Live authority (Mac grant): the saved review must still be this exact chain.
                fun authorized(live: LocalData) = live.settings.backupReview == s.backupReview && CleanupFailover.isReviewed(live.settings)
                fun revoked() = ApiFailure("Backup cleanup was turned off or changed.", ApiFailure.Kind.setup)
                fun authorize() { if(!authorized(failover.value)) throw revoked() }
                // Mac failover metrics: a chain result's model identity is unverified, so it stays unpriced.
                fun unverified(index: Int, g: Generated) = g.copy(usage = g.usage.copy(model = if(index == 0) "Experimental primary; model identity unverified; unpriced"
                    else if(chain[index].anthropic) "Anthropic backup; model identity unverified; unpriced" else "Compatible backup; model identity unverified; unpriced"))
                CleanupFailover.run(chain, clock) { index, endpoint, sendTimeout ->
                    if(index == 0) return@run unverified(0, api.generateWithUsage(raw, data, category, singleLine, null, endpoint, keyFor(endpoint.scope), sendTimeout))
                    val backup = s.backups[index - 1]
                    authorize()
                    val k = if(backup.keyless) "" else keyFor(endpoint.scope)
                    if(!backup.keyless && k.isEmpty()) throw ApiFailure("Save an API key for backup ${index} in API connection.", ApiFailure.Kind.setup)
                    coroutineScope {
                        // Revocation while the backup is in flight cancels the call; coroutineScope drains it.
                        val watch = launch { failover.first { !authorized(it) }; throw revoked() }
                        try { api.generateWithUsage(raw, data, category, singleLine, null, endpoint, k) { authorize(); sendTimeout() } } finally { watch.cancel() }
                    }.also { authorize() }.let { unverified(index, it) }
                }
            } else api.generateWithUsage(raw, data, category, singleLine, instruction, primary, keyFor(primary.scope))
            val result = if(transform) output.text.trim() else PromptBuilder.sanitize(output.text)
            outputCheck(result.isNotEmpty(), "Cleanup returned no text")
            if(transform) outputCheck(result.countCharacters() <= maxOf(2000, 6 * raw.countCharacters()), "The preset returned too much text")
            else cleanupLengthFailure(raw, result, data.snippets)?.let { throw ApiFailure(it) }
            CleanupResult(if(transform) result else TextRules.replace(result, data.replacements), usage = output.usage)
        } catch(c: CancellationException) { throw c }
        catch(e: Exception) {
            // Library exceptions can include entire header values. Only our bounded, safe failures reach UI/history.
            val reason = if(e is ApiFailure) e.message.orEmpty() else "Text cleanup failed"
            CleanupResult(if(s.outputMode == "selectedPreset") raw else TextRules.replace(raw, data.replacements), "$reason · original preserved")
        }
    }
    private fun outputCheck(valid: Boolean, message: String) {
        if (!valid) throw ApiFailure(message)
    }
}

/** Ordinary cleanup length bounds; null when [result] is acceptable for [raw]. */
internal fun cleanupLengthFailure(raw: String, result: String, snippets: List<Snippet>): String? {
    fun folded(text: String) = java.text.Normalizer.normalize(text.lowercase(java.util.Locale.ROOT), java.text.Normalizer.Form.NFC)
    val lower = folded(raw)
    val allowance = 2 * raw.countCharacters() + 200 + snippets.sumOf { sn ->
        if(sn.trigger.isEmpty()) 0 else Regex(Regex.escape(folded(sn.trigger))).findAll(lower).count() * sn.expansion.countCharacters()
    }
    return if(result.countCharacters() > allowance) "Cleanup returned invalid text"
        else if(raw.countCharacters() >= 80 && result.countCharacters() < raw.countCharacters()/5) "Cleanup returned truncated text" else null
}
