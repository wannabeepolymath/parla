package dev.parla.android

import java.time.Instant
import java.time.ZoneOffset
import java.time.format.DateTimeFormatter
import java.time.temporal.ChronoUnit

internal const val MAX_HISTORY_SHARE_BYTES = 100 * 1024

/**
 * Port of the desktop TranscriptExport. Export data is deliberately smaller than HistoryEntry:
 * only the chosen text, its date and an optional app label cross this boundary (no note, model or latency).
 */
internal object TranscriptExport {
    enum class Content(val label: String) { original("Original"), result("Result") }
    enum class Format(val label: String, val extension: String, val mime: String) {
        text("Plain text", "txt", "text/plain"), markdown("Markdown", "md", "text/markdown");
        fun filename(now: Long): String = "parla-transcripts-${DateTimeFormatter.ofPattern("yyyy-MM-dd").withZone(ZoneOffset.UTC).format(Instant.ofEpochMilli(now))}.$extension"
    }

    fun encode(rows: List<HistoryEntry>, content: Content, format: Format, appLabel: (String) -> String = { it }): String =
        rows.mapIndexed { index, row ->
            val text = if(content == Content.original) row.raw else row.text
            // Desktop ISO8601DateFormatter default: UTC, whole seconds.
            val metadata = "Entry ${index + 1} · ${Instant.ofEpochMilli(row.createdAt).truncatedTo(ChronoUnit.SECONDS)} · ${content.label}"
            val app = row.app.takeIf { it.isNotEmpty() }?.let { "App: " + metadata(appLabel(it), format == Format.markdown) }
            when(format) {
                Format.text -> listOfNotNull(metadata, app).joinToString("\n") + "\n\n" + text + "\n"
                Format.markdown -> {
                    // A fence longer than every backtick run cannot be closed by any transcript line.
                    val longest = Regex("`+").findAll(text).maxOfOrNull { it.value.length } ?: 0
                    val fence = "`".repeat(maxOf(3, longest + 1))
                    // Swift treats "\r\n" as one Character, so it never has the "\n" suffix.
                    val ended = text.endsWith("\n") && !text.endsWith("\r\n")
                    "## " + metadata + "\n" + (app?.let { "\n" + it + "\n" } ?: "") + "\n" + fence + "text\n" + text + (if(ended) "" else "\n") + fence + "\n"
                }
            }
        }.joinToString(if(format == Format.text) "\n--------\n\n" else "\n---\n\n")

    /** Single-line, inert metadata: controls become escapes or spaces; Markdown punctuation is escaped. */
    fun metadata(value: String, markdown: Boolean): String = buildString {
        value.codePoints().forEach { c ->
            when(c) {
                10 -> append("\\n"); 13 -> append("\\r"); 9 -> append("\\t")
                in 0..31, 127, 0x85, 0x2028, 0x2029 -> append(' ')
                else -> {
                    if(markdown && (c in 33..47 || c in 58..64 || c in 91..96 || c in 123..126)) append('\\')
                    appendCodePoint(c)
                }
            }
        }
    }
}

/** Desktop filteredHistory: case-insensitive match on original, result or app. */
internal fun filterHistory(rows: List<HistoryEntry>, query: String, appLabel: (String) -> String = { it }): List<HistoryEntry> =
    if(query.isEmpty()) rows else rows.filter { row ->
        row.raw.contains(query, true) || row.text.contains(query, true) ||
            row.app.isNotEmpty() && (row.app.contains(query, true) || appLabel(row.app).contains(query, true))
    }

internal fun writeHistoryExport(pending: String, write: (String) -> Unit): String {
    if(pending.isEmpty()) return "Export interrupted. Please export again."
    return try {
        write(pending)
        "History exported"
    } catch(_: Exception) { "Export failed. Saved history is unchanged; choose a writable destination." }
}

internal fun shareHistory(text: String, launch: (String) -> Unit): String {
    if(text.toByteArray(Charsets.UTF_8).size > MAX_HISTORY_SHARE_BYTES) return "History is too large to share. Use Export file."
    return try {
        launch(text)
        ""
    } catch(_: Exception) { "Could not share history. Try Export file." }
}
