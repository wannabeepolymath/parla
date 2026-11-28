package dev.parla.android

import org.junit.Assert.*
import org.junit.Test

class HistoryExportTest {
    // 2026-11-28T10:15:30.789Z; desktop exports whole UTC seconds.
    private val at = 1795860930789L
    private fun row(raw: String = "original", text: String = "result", app: String = "", note: String = "internal note") =
        HistoryEntry(createdAt = at, raw = raw, text = text, note = note, app = app, model = "base.en", latencyMs = 1234)

    @Test fun plainTextMatchesDesktopLayoutAndExcludesInternalFields() {
        val rows = listOf(row(app = "com.whatsapp"), row(raw = "second raw", text = "second"))
        val out = TranscriptExport.encode(rows, TranscriptExport.Content.result, TranscriptExport.Format.text) { if(it == "com.whatsapp") "WhatsApp" else it }
        assertEquals("Entry 1 · 2026-11-28T10:15:30Z · Result\nApp: WhatsApp\n\nresult\n\n--------\n\nEntry 2 · 2026-11-28T10:15:30Z · Result\n\nsecond\n", out)
        val original = TranscriptExport.encode(rows, TranscriptExport.Content.original, TranscriptExport.Format.text)
        assertTrue(original.contains("· Original\nApp: com.whatsapp\n\noriginal\n")); assertFalse(original.contains("result"))
        for(text in listOf(out, original)) for(hidden in listOf("internal note", "base.en", "1234", "Base")) assertFalse(text.contains(hidden))
    }

    @Test fun markdownFencesOutlastBacktickRunsAndKeepTextVerbatim() {
        val tricky = "## heading\n````\ncode\n```\n<b>x</b>"
        val out = TranscriptExport.encode(listOf(row(text = tricky)), TranscriptExport.Content.result, TranscriptExport.Format.markdown)
        assertEquals("## Entry 1 · 2026-11-28T10:15:30Z · Result\n\n`````text\n$tricky\n`````\n", out)
        // An existing trailing newline is not doubled; "\r\n" is one Swift Character and still gets "\n".
        assertEquals("## Entry 1 · 2026-11-28T10:15:30Z · Result\n\n```text\nend\n```\n",
            TranscriptExport.encode(listOf(row(text = "end\n")), TranscriptExport.Content.result, TranscriptExport.Format.markdown))
        assertTrue(TranscriptExport.encode(listOf(row(text = "end\r\n")), TranscriptExport.Content.result, TranscriptExport.Format.markdown).endsWith("end\r\n\n```\n"))
        val two = TranscriptExport.encode(listOf(row(), row()), TranscriptExport.Content.original, TranscriptExport.Format.markdown)
        assertEquals(1, Regex("\n---\n\n").findAll(two).count())
    }

    @Test fun appMetadataIsSingleLineAndMarkdownInert() {
        assertEquals("a\\nb\\rc\\td e f g", TranscriptExport.metadata("a\nb\rc\td\u0001e f\u0085g", false))
        assertEquals("\\*\\[x\\]\\(y\\)\\# \\<b\\> \\`z\\` ü", TranscriptExport.metadata("*[x](y)# <b> `z` ü", true))
        assertEquals("*[x](y)#", TranscriptExport.metadata("*[x](y)#", false))
        val out = TranscriptExport.encode(listOf(row(app = "x")), TranscriptExport.Content.result, TranscriptExport.Format.markdown) { "Evil\n## App*" }
        assertTrue(out.contains("\nApp: Evil\\n\\#\\# App\\*\n"))
    }

    @Test fun filenameUsesUtcDateAndFormatExtension() {
        assertEquals("parla-transcripts-2026-11-28.txt", TranscriptExport.Format.text.filename(at))
        assertEquals("parla-transcripts-2026-11-28.md", TranscriptExport.Format.markdown.filename(at))
    }

    @Test fun filterMatchesOriginalResultOrAppIgnoringCase() {
        val a = row(raw = "Meeting notes", text = "cleaned", app = "com.slack")
        val b = row(raw = "groceries", text = "Buy MILK")
        val rows = listOf(a, b)
        assertEquals(rows, filterHistory(rows, ""))
        assertEquals(listOf(a), filterHistory(rows, "meeting"))
        assertEquals(listOf(b), filterHistory(rows, "milk"))
        assertEquals(listOf(a), filterHistory(rows, "SLACK"))
        assertEquals(listOf(a), filterHistory(rows, "Team chat") { "Team Chat" })
        assertEquals(emptyList<HistoryEntry>(), filterHistory(rows, "absent"))
    }

    @Test fun recreatedExportWithoutPayloadNeverOpensDestinationOrReportsSuccess() {
        var writes = 0
        val interrupted = writeHistoryExport("") { writes++ }
        assertEquals(0,writes); assertTrue(interrupted.contains("interrupted")); assertTrue(interrupted.contains("export again"))
        val payload = TranscriptExport.encode(listOf(row()), TranscriptExport.Content.result, TranscriptExport.Format.text)
        assertEquals("History exported",writeHistoryExport(payload) { assertEquals(payload,it); writes++ })
        assertEquals(1,writes)
        assertTrue(writeHistoryExport(payload) { error("unwritable") }.contains("failed"))
    }

    @Test fun sharingBoundsUtf8PayloadAndReportsLaunchFailure() {
        var launches = 0
        fun launch(text: String) { assertTrue(text.toByteArray(Charsets.UTF_8).size <= MAX_HISTORY_SHARE_BYTES); launches++ }
        assertEquals("",shareHistory("x".repeat(MAX_HISTORY_SHARE_BYTES),::launch)); assertEquals(1,launches)
        val large = TranscriptExport.encode(List(1000) { row(raw = "❤️".repeat(100)) }, TranscriptExport.Content.original, TranscriptExport.Format.markdown)
        assertTrue(shareHistory(large,::launch).contains("Export file")); assertEquals(1,launches)
        assertTrue(shareHistory("é".repeat(MAX_HISTORY_SHARE_BYTES/2+1),::launch).contains("too large")); assertEquals(1,launches)
        assertTrue(shareHistory("small") { throw IllegalStateException("No share activity") }.contains("Could not share"))
    }

    @Test fun historyMetadataRoundTripsThroughLocalDataCodec() {
        val entry = row(app = "com.whatsapp")
        val decoded = LocalDataCodec.decode(LocalDataCodec.encode(LocalData(history = listOf(entry)))).history.single()
        assertEquals(entry, decoded)
        // Rows written before these fields existed still load with "unknown" metadata.
        val legacy = org.json.JSONObject(LocalDataCodec.encode(LocalData(history = listOf(entry))))
        legacy.getJSONArray("history").getJSONObject(0).apply { remove("app"); remove("model"); remove("latencyMs") }
        val old = LocalDataCodec.decode(legacy.toString()).history.single()
        assertEquals("", old.app); assertEquals("", old.model); assertEquals(0L, old.latencyMs)
        assertEquals("WhatsApp · Base · English · Ready in 1.2 s", historyDetails(entry) { "WhatsApp" })
        assertEquals("", historyDetails(old) { it })
    }
}
