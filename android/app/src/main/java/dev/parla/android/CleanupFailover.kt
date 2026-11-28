package dev.parla.android

import java.security.MessageDigest

/** Backup key source: the key saved for this backup's address, or none (custom servers only). */
data class CleanupBackup(val provider: String = "custom", val baseUrl: String = "", val model: String = "", val keyless: Boolean = false)

/**
 * Mac CleanupFailover rules: ordinary dictation only, at most two reviewed backups, one shared
 * 15-second budget, a backup starts only with at least 3 seconds left, and only transient failures advance.
 * The review is a digest of every destination, so any identity edit turns backups off until reviewed again.
 */
internal object CleanupFailover {
    const val MAX_BACKUPS = 2
    const val BUDGET_MS = 15_000L
    const val MIN_BACKUP_MS = 3_000L

    data class Identity(val label: String, val endpoint: String, val model: String, val key: String)

    fun validModel(value: String) = value.isNotEmpty() && value.toByteArray().size <= 160 &&
        value.all { it in 'A'..'Z' || it in 'a'..'z' || it in '0'..'9' || it in "-./:_" }

    /** The exact chain a review would confirm; throws when it cannot be turned on. */
    fun chain(settings: Settings): List<Pair<Endpoint, Identity>> {
        val backups = settings.backups
        if (backups.isEmpty() || backups.size > MAX_BACKUPS) throw ApiFailure("Add one or two backups first.", ApiFailure.Kind.setup)
        val primary = settings.endpoint()
        val rows = listOf(primary to (if (primary.custom) "Saved key, or none" else "Saved key")) + backups.map { b ->
            val e = b.endpoint()
            if (b.keyless && !e.custom) throw ApiFailure("Only a custom server can be used without a key.", ApiFailure.Kind.setup)
            e to (if (b.keyless) "No key" else "Saved key")
        }
        if (rows.any { !validModel(it.first.model) }) throw ApiFailure("Every service in the chain needs an exact model ID.", ApiFailure.Kind.setup)
        if (rows.map { it.first.scope + "\n" + it.first.model }.distinct().size != rows.size) throw ApiFailure("Each backup must use a different service or model.", ApiFailure.Kind.setup)
        return rows.map { (e, key) -> e to Identity(e.label, e.baseUrl, e.model, key) }
    }
    fun digest(settings: Settings): String {
        val text = "ordinary-bounded-v1\n" + chain(settings).joinToString("\n\n") { (e, id) -> listOf(e.provider, e.scope, e.model, id.key).joinToString("\n") }
        return MessageDigest.getInstance("SHA-256").digest(text.toByteArray()).joinToString("") { "%02x".format(it) }
    }
    fun isReviewed(settings: Settings) = settings.backupReview.isNotEmpty() && runCatching { digest(settings) }.getOrNull() == settings.backupReview

    /** [attempt] receives the remaining shared budget. Cancellation always propagates. */
    suspend fun run(chain: List<Endpoint>, clock: () -> Long, attempt: suspend (Int, Endpoint, Long) -> String): String {
        val deadline = clock() + BUDGET_MS
        var last: ApiFailure? = null
        for ((index, endpoint) in chain.withIndex()) {
            val remaining = deadline - clock()
            last?.let { if (remaining < MIN_BACKUP_MS || !it.transient) throw it }
            try { return attempt(index, endpoint, remaining) } catch (failure: ApiFailure) { last = failure }
        }
        throw last!!
    }
}
