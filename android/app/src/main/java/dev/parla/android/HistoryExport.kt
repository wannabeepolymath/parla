package dev.parla.android

internal const val MAX_HISTORY_SHARE_BYTES = 100 * 1024

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
