package dev.parla.android

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** P1-07: pure split plan, sequential bounded requests, all-or-nothing preview, no failover. Mock HTTP only. */
class SegmentedRetryTest {
    private fun reason(block: () -> Unit) = (runCatching(block).exceptionOrNull() as? SegmentedFailure)?.reason
    private fun words(bytes: Int, word: String = "word") = generateSequence { word }.take(bytes).joinToString(" ").take(bytes).trimEnd()
    private fun reply(text: String, input: Int? = 10, model: String = "m") = MockResponse().setBody(JSONObject().put("model", model)
        .put("choices", JSONArray().put(JSONObject().put("finish_reason", "stop").put("message", JSONObject().put("content", text))))
        .put("usage", JSONObject().putOpt("prompt_tokens", input).put("completion_tokens", 2)).toString())

    @Test fun planReconstructsTheExactSourceAndBoundsEverySection() {
        val sources = listOf(
            "  \n" + words(3000) + ".\r\n\r\n" + words(3000) + "! " + words(5000) + " \t\n",
            (1..9).joinToString("\n\n") { words(2500) } ,
            words(3000, "नमस्ते") + "  " + words(3000, "👋🏽x") + " " + words(1000),
        )
        for(source in sources) {
            val plan = SegmentPlan(source)
            assertEquals(source, plan.reconstructed())
            assertTrue(plan.segments.size in 2..16)
            for(s in plan.segments) {
                val content = plan.content(s)
                assertTrue(utf8Bytes(content) in 1..4096)
                assertFalse(content.first().isWhitespace() || content.last().isWhitespace())
                assertTrue(plan.separator(s).all { it.isWhitespace() })
            }
        }
    }

    @Test fun planPrefersParagraphThenSentenceThenAnyWhitespace() {
        // A paragraph after 2048 bytes wins over a later sentence end.
        val paragraph = SegmentPlan(words(2100) + "\n\n" + words(1000) + ". " + words(3000))
        assertEquals("\n\n", paragraph.separator(paragraph.segments[0]))
        val sentence = SegmentPlan(words(2100) + ". " + words(1000) + " " + words(3000))
        assertTrue(sentence.content(sentence.segments[0]).endsWith("."))
        // Before 2048 bytes only plain whitespace qualifies, so the split is the last space within 4096 bytes.
        val plain = SegmentPlan(words(1000) + "\n\n" + words(6000))
        assertTrue(utf8Bytes(plain.content(plain.segments[0])) > 4000)
        // CRLF pairs count as one newline each, as Swift Characters do.
        val crlf = SegmentPlan(words(2100) + "\r\n" + words(1000) + ". " + words(3000))
        assertEquals(". ".drop(1), crlf.separator(crlf.segments[0]))
    }

    @Test fun planRefusalsMatchTheDesktop() {
        assertEquals(SegmentedFailure.Reason.singleSegment, reason { SegmentPlan("short text") })
        assertEquals(SegmentedFailure.Reason.source, reason { SegmentPlan("") })
        assertEquals(SegmentedFailure.Reason.source, reason { SegmentPlan("   ") })
        assertEquals(SegmentedFailure.Reason.source, reason { SegmentPlan(words(64 * 1024 + 1)) })
        assertEquals(SegmentedFailure.Reason.plan, reason { SegmentPlan("x".repeat(4097)) }) // no whitespace to split at
        assertEquals(SegmentedFailure.Reason.plan, reason { SegmentPlan(words(64 * 1024)) }) // more than 16 sections
        SegmentPlan("x".repeat(4096) + " " + "y")
    }

    @Test fun sectionsRunSequentiallyAndAssembleOnePreviewWithSeparatorsAndRulesOnce() = runBlocking {
        MockWebServer().use { server ->
            val source = words(3000, "alpha") + "\n\n" + words(3000, "beta") + "\n\n" + words(2000, "gamma")
            val retry = SegmentedRetry(HistoryEntry(raw = source, text = "old"), LocalData(compatible(server.url("/v1").toString()), replacements = listOf(LiteralReplacement("ONE", "1"))))
            assertEquals(3, retry.planned); assertTrue(retry.disclosure.contains("At most 3 requests"))
            listOf("A ONE", "B", "C").forEachIndexed { i, t -> server.enqueue(reply(t + " " + source.split("\n\n")[i].take(2000), input = 10 + i)) }
            val out = retry.run({ "" }, Pipeline(ApiClient(OkHttpClient())))
            assertEquals(3, server.requestCount)
            val bodies = (1..3).map { JSONObject(server.takeRequest().body.readUtf8()).getJSONArray("messages").getJSONObject(1).getString("content") }
            assertTrue(bodies[0].contains("alpha") && !bodies[0].contains("beta")); assertTrue(bodies[1].contains("beta")); assertTrue(bodies[2].contains("gamma"))
            assertTrue(out.text.startsWith("A 1 alpha")); assertEquals(2, Regex("\n\n").findAll(out.text).count())
            assertEquals(CleanupUsage("Experimental response usage; model identity unverified", 33, 6), out.usage)
        }
    }

    @Test fun anyFailedSectionDiscardsEverythingAndNeverFailsOver() = runBlocking {
        MockWebServer().use { server -> MockWebServer().use { backup ->
            val source = words(3000) + "\n\n" + words(3000) + "\n\n" + words(3000)
            val settings = compatible(server.url("/v1").toString()).copy(backups = listOf(CleanupBackup("custom", backup.url("/v1").toString(), "other", keyless = true)))
            val reviewed = settings.copy(backupReview = CleanupFailover.digest(settings))
            assertTrue(CleanupFailover.isReviewed(reviewed))
            server.enqueue(reply(words(2900))); server.enqueue(MockResponse().setResponseCode(503))
            val failure = runCatching { SegmentedRetry(HistoryEntry(raw = source, text = "old"), LocalData(reviewed)).run({ "" }, Pipeline(ApiClient(OkHttpClient()))) }.exceptionOrNull() as SegmentedFailure
            assertEquals(SegmentedFailure.Reason.provider, failure.reason)
            assertTrue(failure.message!!.startsWith("Section 2 of 3")); assertTrue(failure.message!!.endsWith("Nothing was changed."))
            assertEquals(2, server.requestCount) // the third section is never sent
            assertEquals(0, backup.requestCount) // history cleanup never uses backups
        } }
    }

    @Test fun reviewRefusesSnippetsVagueModelsAndOversizedRulesAndRunsDeterministicLocally() = runBlocking {
        val source = HistoryEntry(raw = words(3000) + "\n\n" + words(3000), text = "old")
        val base = LocalData(compatible("http://127.0.0.1:9/v1"))
        assertEquals(SegmentedFailure.Reason.snippets, reason { SegmentedRetry(source, base.copy(snippets = listOf(Snippet(trigger = "sig", expansion = "x")))) })
        assertEquals(SegmentedFailure.Reason.configuration, reason { SegmentedRetry(source, LocalData(compatible("http://127.0.0.1:9/v1", model = ""))) })
        assertEquals(SegmentedFailure.Reason.rules, reason { SegmentedRetry(source, base.copy(dictionary = (1..257).map { "w$it" })) })
        assertEquals(SegmentedFailure.Reason.previous, reason { SegmentedRetry(source.copy(text = "x".repeat(128 * 1024 + 1)), base) })
        assertEquals(SegmentedFailure.Reason.singleSegment, reason { SegmentedRetry(HistoryEntry(raw = "short", text = "short"), base) })
        // Cleanup off: local rules only, no plan and nothing sent (the address above would refuse a connection).
        val local = SegmentedRetry(source, base.copy(settings = base.settings.copy(cleanupEnabled = false), replacements = listOf(LiteralReplacement("word", "w"))))
        assertTrue(local.deterministic); assertNull(local.plan); assertTrue(local.disclosure.contains("nothing is sent online"))
        assertTrue(local.run({ error("no key needed") }).text.startsWith("w w"))
    }

    @Test fun usageTotalsOnlyWhenEveryRequestReportedThemAndMixedModelsAreUnpriced() {
        assertEquals(CleanupUsage("Experimental response usage; model identity unverified", 3, 7), SegmentedRetry.usage(listOf(CleanupUsage("m", 1, 3), CleanupUsage("m", 2, 4))))
        assertEquals(CleanupUsage("Experimental response usage; model identity unverified", null, 7), SegmentedRetry.usage(listOf(CleanupUsage("m", null, 3), CleanupUsage("m", 2, 4))))
        assertEquals("Mixed response models; usage not priced", SegmentedRetry.usage(listOf(CleanupUsage("a", 1, 1), CleanupUsage("b", 1, 1)))!!.model)
        assertNull(SegmentedRetry.usage(listOf(CleanupUsage("m", null, null))))
        assertNull(CleanupPricing.usd(SegmentedRetry.usage(listOf(CleanupUsage("claude-haiku-4-5", 1, 1)))!!.model, 1, 1))
    }
}
