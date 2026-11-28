package dev.parla.android

/**
 * Mac CleanupPricing: USD list price per million tokens, keyed by model-id prefix (longest wins).
 * ponytail: hardcoded and dated; re-check against provider pricing pages each release. A model that is
 * not listed is unpriced, never free.
 */
internal object CleanupPricing {
    /** When these list prices were last checked (the Mac table's source). Shown beside every estimate. */
    const val CHECKED = "August 2026"
    private val perMTok = mapOf(
        "claude-opus-4-5" to (15.0 to 75.0),
        "claude-sonnet-5" to (3.0 to 15.0),
        "claude-haiku-4-5" to (1.0 to 5.0),
        "gemini-2.5-flash" to (0.30 to 2.50),
        "gemini-2.5-flash-lite" to (0.10 to 0.40),
        "gpt-5-nano" to (0.05 to 0.40),
    )
    fun usd(model: String, input: Int, output: Int): Double? =
        perMTok.keys.filter { model.startsWith(it) }.maxByOrNull { it.length }?.let { perMTok.getValue(it) }
            ?.let { (i, o) -> (input * i + output * o) / 1_000_000 }
}

/** Mac CleanupCostEstimate: a sample over saved history, never a bill. Monthly only after an hour of span. */
internal data class CleanupCostEstimate(val usd: Double, val dictations: Int, val unpriced: Int, val since: Long, val monthlyUsd: Double?) {
    companion object {
        fun over(rows: List<HistoryEntry>, now: Long = System.currentTimeMillis()): CleanupCostEstimate? {
            var usd = 0.0; var priced = 0; var unpriced = 0; var since = now
            for(row in rows) {
                val input = row.inputTokens ?: continue; val output = row.outputTokens ?: continue
                since = minOf(since, row.createdAt)
                val cost = row.cleanupModel.takeIf { it.isNotEmpty() }?.let { CleanupPricing.usd(it, input, output) }
                if(cost != null) { usd += cost; priced++ } else unpriced++
            }
            if(priced + unpriced == 0) return null
            val span = (now - since) / 1000.0
            return CleanupCostEstimate(usd, priced + unpriced, unpriced, since, if(span >= 3600) usd / span * 2_592_000 else null)
        }
        /** Per-dictation spend is fractions of a cent, so small amounts keep four decimals. */
        fun money(usd: Double) = if(usd < 1) "$%.4f".format(java.util.Locale.ROOT, usd) else "$%.2f".format(java.util.Locale.ROOT, usd)
    }
}
