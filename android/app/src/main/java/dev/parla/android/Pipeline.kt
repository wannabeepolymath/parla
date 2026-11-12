package dev.parla.android

import kotlinx.coroutines.CancellationException

/** Frozen output settings; neither editor text nor package identifiers leave the device. */
class Pipeline(private val api: ApiClient = ApiClient()) {
    suspend fun clean(raw: String, data: LocalData, category: AppCategory = AppCategory.unknown, singleLine: Boolean = false, key: () -> String): CleanupResult {
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
            val output = api.generate(raw, data, category, singleLine, instruction, key())
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
            CleanupResult(if(transform) result else TextRules.replace(result, data.replacements))
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
