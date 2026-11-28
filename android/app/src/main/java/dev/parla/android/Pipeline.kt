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
    suspend fun clean(raw: String, data: LocalData, category: AppCategory = AppCategory.unknown, singleLine: Boolean = false, failover: StateFlow<LocalData>? = null,
                      nearby: NearbyContext? = null, key: (String) -> String): CleanupResult {
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
                selectedIntent(data)
            } else null
            fun keyFor(scope: String) = keyFor(key, scope)
            val primary = s.endpoint()
            var contextual = false
            val output = if(failover != null && !transform && CleanupFailover.isReviewed(s)) {
                val chain = listOf(primary) + s.backups.map { it.endpoint() }
                // Live authority (Mac grant): the saved review must still be this exact chain.
                fun authorized(live: LocalData) = live.settings.backupReview == s.backupReview && CleanupFailover.isReviewed(live.settings)
                fun revoked() = ApiFailure("Backup cleanup was turned off or changed.", ApiFailure.Kind.setup)
                fun authorize() { if(!authorized(failover.value)) throw revoked() }
                CleanupFailover.run(chain, clock) { index, endpoint, sendTimeout ->
                    if(index == 0) return@run api.generate(raw, data, category, singleLine, null, endpoint, keyFor(endpoint.scope), sendTimeout)
                    val backup = s.backups[index - 1]
                    authorize()
                    val k = if(backup.keyless) "" else keyFor(endpoint.scope)
                    if(!backup.keyless && k.isEmpty()) throw ApiFailure("Save an API key for backup ${index} in API connection.", ApiFailure.Kind.setup)
                    coroutineScope {
                        // Revocation while the backup is in flight cancels the call; coroutineScope drains it.
                        val watch = launch { failover.first { !authorized(it) }; throw revoked() }
                        try { api.generate(raw, data, category, singleLine, null, endpoint, k, sendTimeoutMs = { authorize(); sendTimeout() }) } finally { watch.cancel() }
                    }.also { authorize() }
                }
            } else if(!transform && nearby != null && nearby.prefix.isNotEmpty() && nearby.authorized() &&
                (PromptBuilder.system(data, category, singleLine, preceding = true) + PromptBuilder.user(raw, preceding = nearby.prefix)).toByteArray().size <= NearbyText.MAX_REQUEST_BYTES) {
                val k = keyFor(primary.scope)
                contextual = true
                val first = api.generate(raw, data, category, singleLine, null, primary, k, preceding = nearby.prefix)
                // Mac: one context-free retry when the reply copies nearby text; a second copy fails the cleanup.
                val out = if(NearbyText.echoes(nearby.prefix, first, raw)) api.generate(raw, data, category, singleLine, null, primary, k)
                    .also { outputCheck(!NearbyText.echoes(nearby.prefix, it, raw), "Cleanup repeated nearby text") } else first
                if(!nearby.authorized()) throw ApiFailure("Nearby text was turned off or changed.", ApiFailure.Kind.setup)
                out
            } else api.generate(raw, data, category, singleLine, instruction, primary, keyFor(primary.scope))
            val result = if(transform) output.trim() else PromptBuilder.sanitize(output)
            outputCheck(result.isNotEmpty(), "Cleanup returned no text")
            if(transform) outputCheck(result.countCharacters() <= maxOf(2000, 6 * raw.countCharacters()), "The preset returned too much text")
            else {
                fun folded(text: String) = java.text.Normalizer.normalize(text.lowercase(java.util.Locale.ROOT), java.text.Normalizer.Form.NFC)
                val lower = folded(raw)
                val allowance = 2 * raw.countCharacters() + 200 + data.snippets.sumOf { sn ->
                    if(sn.trigger.isEmpty()) 0 else Regex(Regex.escape(folded(sn.trigger))).findAll(lower).count() * sn.expansion.countCharacters()
                }
                outputCheck(result.countCharacters() <= allowance, "Cleanup returned invalid text")
                outputCheck(raw.countCharacters() < 80 || result.countCharacters() >= raw.countCharacters()/5, "Cleanup returned truncated text")
            }
            CleanupResult(if(transform) result else TextRules.replace(result, data.replacements), contextual = contextual)
        } catch(c: CancellationException) { throw c }
        catch(e: Exception) {
            // Library exceptions can include entire header values. Only our bounded, safe failures reach UI/history.
            val reason = if(e is ApiFailure) e.message.orEmpty() else "Text cleanup failed"
            CleanupResult(if(s.outputMode == "selectedPreset") raw else TextRules.replace(raw, data.replacements), "$reason · original preserved")
        }
    }
    /**
     * Mac IntentionalTransform on a frozen selection: [instruction] (a preset intent or spoken command) applied to
     * [source] with dictionary spellings only. Trim-only bounded output. A failure returns a warning, never text to write.
     */
    suspend fun transform(source: String, instruction: String, data: LocalData, key: (String) -> String): CleanupResult = try {
        outputCheck(source.isNotEmpty(), "Select some text to change, then try again.")
        outputCheck(instruction.isNotBlank(), "No instruction was heard. Try again.")
        outputCheck(data.settings.cleanupEnabled, "Turn on AI cleanup in Output settings to change selected text.")
        val primary = data.settings.endpoint()
        val result = api.generate(source, data, AppCategory.unknown, false, instruction, primary, keyFor(key, primary.scope)).trim()
        outputCheck(result.isNotEmpty() && result.countCharacters() <= maxOf(2000, 6 * source.countCharacters()), "The provider returned no usable text.")
        CleanupResult(result)
    } catch(c: CancellationException) { throw c }
    catch(e: Exception) { CleanupResult(source, (if(e is ApiFailure) e.message.orEmpty() else "Text change failed") + " · nothing changed") }

    /** The selected preset's exact intent, shared by dictated and selected-text presets. */
    fun selectedIntent(data: LocalData): String {
        val matches = data.presets.filter { it.id == data.settings.selectedPresetID }
        outputCheck(matches.size == 1, "Choose a saved preset in Output settings.")
        val preset = matches.single()
        try { preset.validate() } catch (_: IllegalArgumentException) {
            throw ApiFailure("The selected preset is invalid. Edit it in Output settings.")
        }
        return preset.intent
    }
    private fun keyFor(key: (String) -> String, scope: String) = try { key(scope) } catch(c: CancellationException) { throw c } catch(e: IllegalStateException) {
        // Store's own fixed messages (paused data, Keystore failure); never provider text.
        throw ApiFailure(e.message ?: "Your saved key couldn't be read. Save it again in API connection.", ApiFailure.Kind.setup)
    }
    private fun outputCheck(valid: Boolean, message: String) {
        if (!valid) throw ApiFailure(message)
    }
}
