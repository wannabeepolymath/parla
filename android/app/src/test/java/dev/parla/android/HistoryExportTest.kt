package dev.parla.android

import org.junit.Assert.*
import org.junit.Test

class HistoryExportTest {
    @Test fun recreatedExportWithoutPayloadNeverOpensDestinationOrReportsSuccess() {
        var writes = 0
        val interrupted = writeHistoryExport("") { writes++ }
        assertEquals(0,writes); assertTrue(interrupted.contains("interrupted")); assertTrue(interrupted.contains("export again"))
        val payload = exportHistory(listOf(HistoryEntry(raw = "original",text = "result")),false)
        assertEquals("History exported",writeHistoryExport(payload) { assertEquals(payload,it); writes++ })
        assertEquals(1,writes)
        assertTrue(writeHistoryExport(payload) { error("unwritable") }.contains("failed"))
    }
    @Test fun sharingBoundsUtf8PayloadAndReportsLaunchFailure() {
        var launches = 0
        fun launch(text: String) { assertTrue(text.toByteArray(Charsets.UTF_8).size <= MAX_HISTORY_SHARE_BYTES); launches++ }
        assertEquals("",shareHistory("x".repeat(MAX_HISTORY_SHARE_BYTES),::launch)); assertEquals(1,launches)
        val large = exportHistory(List(1000) { HistoryEntry(raw = "❤️".repeat(100),text = "allowed history") },true)
        assertTrue(shareHistory(large,::launch).contains("Export file")); assertEquals(1,launches)
        assertTrue(shareHistory("é".repeat(MAX_HISTORY_SHARE_BYTES/2+1),::launch).contains("too large")); assertEquals(1,launches)
        assertTrue(shareHistory("small") { throw IllegalStateException("No share activity") }.contains("Could not share"))
    }
}
