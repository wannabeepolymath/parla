package dev.parla.android

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** P2-05 structured usage and cost, plus P1-01 storage-only pending-save retry. Mock HTTP only. */
class CleanupUsageTest {
    private val api = ApiClient(OkHttpClient())

    @Test fun anthropicUsageIsParsedFromTheResponse() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("""{"model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"Hi."}],"stop_reason":"end_turn","usage":{"input_tokens":12,"output_tokens":3}}"""))
            val g = api.generateWithUsage("hi", LocalData(), AppCategory.unknown, false, null, Endpoint("anthropic", server.url("/v1").toString().trimEnd('/'), "claude-haiku-4-5"), "sk-ant-test-123")
            assertEquals("Hi.", g.text)
            assertEquals(CleanupUsage("claude-haiku-4-5-20251001", 12, 3), g.usage)
        }
    }

    @Test fun openAICompatibleUsageIsParsedAndMissingModelFallsBackToTheRequest() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("""{"model":"gpt-5-nano-2025-08-07","choices":[{"finish_reason":"stop","message":{"content":"Hi."}}],"usage":{"prompt_tokens":20,"completion_tokens":5}}"""))
            server.enqueue(MockResponse().setBody("""{"choices":[{"finish_reason":"stop","message":{"content":"Hi."}}]}"""))
            val e = compatible(server.url("/v1").toString(), "local-model").endpoint()
            assertEquals(CleanupUsage("gpt-5-nano-2025-08-07", 20, 5), api.generateWithUsage("hi", LocalData(), AppCategory.unknown, false, null, e, "").usage)
            assertEquals(CleanupUsage("local-model", null, null), api.generateWithUsage("hi", LocalData(), AppCategory.unknown, false, null, e, "").usage)
        }
    }

    @Test fun malformedUsageIsUnknownNeverAFailureAndTheKeyIsRedacted() {
        fun usage(json: String, anthropic: Boolean = false, key: String = "") = responseUsage(JSONObject(json), anthropic, "requested", key)
        assertEquals(CleanupUsage("requested", null, null), usage("""{"usage":{"prompt_tokens":"20","completion_tokens":-1}}"""))
        assertEquals(CleanupUsage("requested", null, 4), usage("""{"usage":{"input_tokens":1.5,"output_tokens":4}}""", anthropic = true))
        assertEquals(CleanupUsage("requested", null, null), usage("""{"model":"","usage":{"input_tokens":12}}"""))
        assertEquals("requested", usage("""{"model":"${"m".repeat(161)}"}""").model)
        assertEquals("requested", usage("""{"model":"bad\u0007model"}""").model)
        assertEquals("echo-[redacted]", usage("""{"model":"echo-sk-secret"}""", key = "sk-secret").model)
        // The wire formats never cross: Anthropic names are ignored on the OpenAI-compatible path.
        assertEquals(CleanupUsage("requested", null, null), usage("""{"usage":{"input_tokens":1,"output_tokens":2}}"""))
    }

    @Test fun pipelineReturnsUsageAndHistoryPersistsIt() = runBlocking {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("""{"model":"m-1","choices":[{"finish_reason":"stop","message":{"content":"Hello there."}}],"usage":{"prompt_tokens":7,"completion_tokens":2}}"""))
            val result = Pipeline(api).clean("hello there", LocalData(compatible(server.url("/v1").toString()))) { "" }
            assertNull(result.warning); assertEquals(CleanupUsage("m-1", 7, 2), result.usage)
        }
        val row = HistoryEntry(raw = "a", text = "b", cleanupModel = "claude-haiku-4-5", inputTokens = 10, outputTokens = 0)
        val decoded = LocalDataCodec.decode(LocalDataCodec.encode(LocalData(history = listOf(row, row.copy(id = "2", cleanupModel = "", inputTokens = null, outputTokens = null)))))
        assertEquals(listOf(row, row.copy(id = "2", cleanupModel = "", inputTokens = null, outputTokens = null)), decoded.history)
        val json = LocalDataCodec.encode(LocalData(history = listOf(row)))
        for(bad in listOf("\"5\"", "-1", "1.5")) assertTrue(bad, runCatching { LocalDataCodec.decode(json.replace("\"inputTokens\":10", "\"inputTokens\":$bad")) }.isFailure)
    }

    @Test fun pendingRetryKeepsTheRowWhenTheHistoryLimitWouldTrimIt() {
        PendingHistory.value.value.forEach { PendingHistory.discard(it.id) }
        var disk: String? = null
        val state = LocalState(object : StateStorage { override fun read() = disk; override fun write(value: String) { disk = value }; override fun preserveOriginal() {} })
        val newer = (1..50).map { HistoryEntry(createdAt = 10_000L + it, raw = "n$it", text = "n$it") }
        assertTrue(state.update { it.copy(history = newer) })
        val old = HistoryEntry(createdAt = 1, raw = "old", text = "old")
        PendingHistory.put(old)
        val message = savePendingEntry(old.id, true, { state.data.value }, state::update)
        assertEquals("History is full (limit 50). Raise the limit in Privacy or delete older entries, then try again.", message)
        assertEquals(listOf(old), PendingHistory.value.value) // the RAM copy is not discarded
        assertFalse(state.data.value.history.any { it.id == old.id })
        // After the limit is raised, the same retry commits and only then drops the kept copy.
        assertTrue(state.update { it.copy(settings = it.settings.copy(historyLimit = 51)) })
        assertEquals("Saved to history", savePendingEntry(old.id, true, { state.data.value }, state::update))
        assertTrue(state.data.value.history.any { it.id == old.id }); assertTrue(PendingHistory.value.value.isEmpty())
        assertTrue(LocalDataCodec.decode(disk!!).history.any { it.id == old.id })
    }

    @Test fun costIsAnEstimateOverHistoryWithUnknownModelsUnpriced() {
        val now = 10_000_000L
        val rows = listOf(
            HistoryEntry(createdAt = now - 2 * 3_600_000, raw = "", text = "", cleanupModel = "claude-haiku-4-5-20251001", inputTokens = 1_000_000, outputTokens = 100_000),
            HistoryEntry(createdAt = now - 1000, raw = "", text = "", cleanupModel = "llama3:8b", inputTokens = 50, outputTokens = 5),
            HistoryEntry(createdAt = now - 1000, raw = "", text = "", cleanupModel = "Experimental primary; model identity unverified; unpriced", inputTokens = 50, outputTokens = 5),
            HistoryEntry(createdAt = 0, raw = "", text = "", cleanupModel = "claude-haiku-4-5", inputTokens = null, outputTokens = 5),
        )
        val est = CleanupCostEstimate.over(rows, now)!!
        assertEquals(1.5, est.usd, 1e-9) // $1/MTok in + $5/MTok out
        assertEquals(3, est.dictations); assertEquals(2, est.unpriced); assertEquals(now - 2 * 3_600_000, est.since)
        assertEquals(1.5 / 7200 * 2_592_000, est.monthlyUsd!!, 1e-6)
        assertNull(CleanupCostEstimate.over(rows.drop(1).take(1), now)!!.monthlyUsd) // under an hour: no projection
        assertNull(CleanupCostEstimate.over(listOf(HistoryEntry(raw = "", text = ""))))
        // Longest prefix wins; unknown is unpriced, never free.
        assertEquals(0.10, CleanupPricing.usd("gemini-2.5-flash-lite-001", 1_000_000, 0)!!, 1e-9)
        assertEquals(0.30, CleanupPricing.usd("gemini-2.5-flash-001", 1_000_000, 0)!!, 1e-9)
        assertNull(CleanupPricing.usd("unknown-model", 1, 1))
        assertEquals("$0.0012", CleanupCostEstimate.money(0.00123)); assertEquals("$12.35", CleanupCostEstimate.money(12.345))
    }

    @Test fun unsavedDictationIsKeptAndRetrySavesWithoutRecognizingOrSendingAgain() = runBlocking {
        PendingHistory.value.value.forEach { PendingHistory.discard(it.id) }
        var recognitions = 0
        val finished = DictationFlow().run(PendingOperation(), LocalData(Settings(outputMode = "raw")), AppCategory.unknown, false, 0,
            transcribe = { recognitions++; "keep me" }, key = { error("raw mode sends nothing") },
            save = { _, _ -> false }, deliver = { _, authorize -> authorize(); "Text inserted." }, stage = { _, _ -> })
        val kept = PendingHistory.value.value.single()
        assertEquals(finished.id, kept.id); assertEquals("keep me", kept.text)
        assertEquals("Text inserted.", kept.note) // the kept row carries the final insertion outcome, not the save failure
        assertFalse(PendingHistory.retry(kept.id) { false }); assertEquals(1, PendingHistory.value.value.size)
        var written: HistoryEntry? = null
        assertTrue(PendingHistory.retry(kept.id) { written = it; true })
        assertEquals(kept, written); assertTrue(PendingHistory.value.value.isEmpty()); assertEquals(1, recognitions)
        // Private (history off) dictation is never kept for saving.
        DictationFlow().run(PendingOperation(), LocalData(Settings(outputMode = "raw", noHistory = true)), AppCategory.unknown, false, 0,
            transcribe = { "private" }, key = { error("none") }, save = { _, _ -> error("never") }, deliver = { _, a -> a(); "Text inserted." }, stage = { _, _ -> })
        assertTrue(PendingHistory.value.value.isEmpty())
        repeat(PendingHistory.MAX + 2) { PendingHistory.put(HistoryEntry(raw = "$it", text = "$it")) }
        assertEquals(PendingHistory.MAX, PendingHistory.value.value.size); assertEquals("${PendingHistory.MAX + 1}", PendingHistory.value.value.first().text)
        PendingHistory.value.value.forEach { PendingHistory.discard(it.id) }
        RecoveryVault.clear()
    }
}
