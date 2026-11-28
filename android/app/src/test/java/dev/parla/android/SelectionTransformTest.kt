package dev.parla.android

import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class SelectionTransformTest {
    private val selected = EditorSnapshot("dev.test", 4, "editor", "1", "EditText", "Hi team, ship it friday. Thanks", 9, 24,
        editable = true, enabled = true, focused = true, visible = true, inputType = 1, password = false)
    private fun reply(text: String) = MockResponse().setBody(JSONObject().put("choices", org.json.JSONArray().put(JSONObject()
        .put("finish_reason", "stop").put("message", JSONObject().put("content", text)))).toString())

    @Test fun frozenSelectionAllowsExactlyOneReplacementOfTheSelectedRange() {
        assertEquals("Hi team, Ship it on Friday. Thanks", InsertionPolicy.replacement(selected, "Ship it on Friday."))
        // Any change to the frozen field or its selection refuses the write.
        listOf(selected.copy(selectionStart = 10), selected.copy(selectionEnd = 23), selected.copy(selectionStart = 24),
            selected.copy(text = "Hi team, ship it monday. Thanks"), selected.copy(windowId = 8))
            .forEach { assertFalse(InsertionPolicy.allows(selected, it, true, true)) }
        assertTrue(InsertionPolicy.allows(selected, selected.copy(), true, true))
    }

    @Test fun transformUsesTheExactDesktopPromptWithTheSelectionAsData() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val data = LocalData(compatible(server.url("/v1").toString()), dictionary = listOf("Siobhán"),
                snippets = listOf(Snippet(trigger = "ship", expansion = "bad")), replacements = listOf(LiteralReplacement("Friday", "bad")))
            server.enqueue(reply("  Ship it on Friday.  "))
            val result = Pipeline(ApiClient(OkHttpClient())).transform("ship it friday.", "make it formal", data) { "k" }
            assertEquals(CleanupResult("Ship it on Friday."), result)
            val messages = JSONObject(server.takeRequest().body.readUtf8()).getJSONArray("messages")
            assertEquals(PromptBuilder.system(data, AppCategory.unknown, false, transforming = true), messages.getJSONObject(0).getString("content"))
            assertTrue(messages.getJSONObject(0).getString("content").startsWith("You transform text according to the user's explicit instruction."))
            assertEquals("make it formal\n\n<text>\nship it friday.", messages.getJSONObject(1).getString("content"))
        }
    }

    @Test fun failedOrUnusableChangesNeverReturnTextToWrite() = runBlocking {
        MockWebServer().use { server ->
            server.start()
            val data = LocalData(compatible(server.url("/v1").toString()))
            val pipeline = Pipeline(ApiClient(OkHttpClient()))
            val none: (String) -> String = { fail("no request may be prepared"); "" }
            assertEquals("Select some text to change, then try again. · nothing changed", pipeline.transform("", "make it formal", data, none).warning)
            assertEquals("No instruction was heard. Try again. · nothing changed", pipeline.transform("text", "  ", data, none).warning)
            assertEquals("Turn on AI cleanup in Output settings to change selected text. · nothing changed",
                pipeline.transform("text", "x", data.copy(settings = data.settings.copy(cleanupEnabled = false)), none).warning)
            assertEquals(0, server.requestCount)
            server.enqueue(reply("   "))
            assertNotNull(pipeline.transform("text", "x", data) { "k" }.warning)
            server.enqueue(reply("y".repeat(2001)))
            assertNotNull(pipeline.transform("text", "x", data) { "k" }.warning)
            server.enqueue(MockResponse().setResponseCode(500))
            assertTrue(pipeline.transform("text", "x", data) { "k" }.warning!!.endsWith("nothing changed"))
        }
    }

    @Test fun flowWritesTheChangeOnceAndAFailedChangeWritesNothing() = runBlocking {
        val data = LocalData(Settings())
        var writes = 0; var saved: HistoryEntry? = null
        val ok = DictationFlow().run(PendingOperation(), data, AppCategory.chat, false, 0,
            transcribe = { "ship it friday." }, key = { error("transform owns the request") },
            save = { row, _ -> saved = row; true },
            deliver = { text, authorize -> assertTrue(authorize()); assertFalse(authorize()); writes++; assertEquals("Ship it\non Friday.".replace("\n", " "), text); DictationFlow.INSERTED },
            stage = { _, _ -> }, transform = { source, _ -> assertEquals("ship it friday.", source); CleanupResult("Ship it\non Friday.") })
        assertEquals(1, writes)
        assertEquals("ship it friday.", ok.raw); assertEquals("Ship it on Friday.", saved!!.text)
        RecoveryVault.clear()

        val failed = DictationFlow().run(PendingOperation(), data, AppCategory.unknown, false, 0,
            transcribe = { "ship it friday." }, key = { error("no key") }, save = { row, _ -> saved = row; true },
            deliver = { _, _ -> fail("a failed change must not write"); "" }, stage = { _, _ -> },
            transform = { source, _ -> CleanupResult(source, "Provider failed · nothing changed") })
        assertEquals("Provider failed · nothing changed", failed.note)
        assertEquals("ship it friday.", saved!!.text)
        assertNull(RecoveryVault.current())
    }
}
