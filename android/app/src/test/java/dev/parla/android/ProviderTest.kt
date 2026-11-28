package dev.parla.android

import java.io.File
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.UnknownHostException
import java.nio.file.Files
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import okhttp3.Dns
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Protocol
import okhttp3.Request
import okhttp3.Response
import okhttp3.ResponseBody.Companion.toResponseBody
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import org.json.JSONArray
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

/** Mock HTTP only: MockWebServer on loopback, or an interceptor that never opens a socket. */
class ProviderTest {
    private val api = ApiClient(OkHttpClient())
    private fun chat(text: String, finish: String = "stop") = JSONObject().put("choices", JSONArray().put(JSONObject().put("finish_reason", finish).put("message", JSONObject().put("content", text)))).toString()
    private suspend fun failure(block: suspend () -> Unit) = (runCatching { block() }.exceptionOrNull() as? ApiFailure) ?: error("expected ApiFailure")

    @Test fun everyHttpStatusMapsToATypedPlainMessageWithoutProviderTextOrKey() = runBlocking {
        MockWebServer().use { server ->
            val e = compatible(server.url("/v1").toString()).endpoint()
            val cases = listOf(
                Triple(400, """{"error":{"code":"model_not_found","type":"invalid_request_error","message":"secret-echo"}}""", ApiFailure.Kind.modelNotFound),
                Triple(400, """{"error":{"type":"invalid_request_error","message":"secret-echo"}}""", ApiFailure.Kind.badRequest),
                Triple(401, """{"error":{"code":"invalid_api_key","message":"Incorrect API key provided: sk-test-123"}}""", ApiFailure.Kind.invalidKey),
                Triple(401, """{"error":{"code":"expired_api_key","message":"secret-echo"}}""", ApiFailure.Kind.expiredKey),
                Triple(403, """{"type":"error","error":{"type":"permission_error","message":"secret-echo"}}""", ApiFailure.Kind.noAccess),
                Triple(404, "secret-echo not json", ApiFailure.Kind.modelNotFound),
                Triple(408, "", ApiFailure.Kind.timeout),
                Triple(413, "", ApiFailure.Kind.tooLarge),
                Triple(429, """{"error":{"code":"rate_limit_exceeded","type":"tokens","message":"secret-echo"}}""", ApiFailure.Kind.rateLimited),
                Triple(429, """{"error":{"code":"insufficient_quota","type":"insufficient_quota","message":"secret-echo"}}""", ApiFailure.Kind.quota),
                Triple(500, "", ApiFailure.Kind.unavailable),
                Triple(503, """[{"error":{"code":503,"message":"secret-echo","status":"UNAVAILABLE"}}]""", ApiFailure.Kind.unavailable),
                Triple(529, """{"type":"error","error":{"type":"overloaded_error","message":"secret-echo"}}""", ApiFailure.Kind.unavailable),
                Triple(302, "", ApiFailure.Kind.redirect),
                Triple(418, "secret-echo", ApiFailure.Kind.other),
            )
            for ((status, body, kind) in cases) {
                server.enqueue(MockResponse().setResponseCode(status).setBody(body).apply { if (status == 302) addHeader("Location", server.url("/elsewhere")) })
                val f = failure { api.generate("hi", LocalData(), AppCategory.unknown, false, null, e, "sk-test-123") }
                assertEquals("$status $body", kind, f.kind); assertEquals(status, f.status)
                for (text in listOf(f.message.orEmpty(), f.detail.orEmpty())) { assertFalse(text, text.contains("secret-echo")); assertFalse(text, text.contains("sk-test")) }
            }
            assertEquals(cases.size, server.requestCount) // the redirect was never followed
            assertEquals("insufficient_quota", httpFailure(429, "insufficient_quota", "insufficient_quota").code)
            assertNull(httpFailure(400, "secret-echo", "sk-test").code) // non-allowlisted codes are dropped
            // Mac failover classification: only 408/429/5xx without a semantic stop are transient.
            for (s in listOf(408, 429, 500, 503, 529)) assertTrue("$s", httpFailure(s, null, null).transient)
            for (s in listOf(400, 401, 403, 404, 413, 302)) assertFalse("$s", httpFailure(s, null, null).transient)
            assertTrue(httpFailure(429, "insufficient_quota", null).transient)
            assertFalse(httpFailure(500, null, "invalid_request_error").transient)
            assertFalse(httpFailure(503, "expired_api_key", null).transient)
        }
    }

    @Test fun transportFailuresAreTypedTimeoutOfflineMalformedAndCancellation() = runBlocking {
        MockWebServer().use { server ->
            val e = compatible(server.url("/v1").toString()).endpoint()
            server.enqueue(MockResponse().setBody("{not json"))
            assertEquals(ApiFailure.Kind.malformed, failure { api.generate("hi", LocalData(), AppCategory.unknown, false, null, e, "k") }.kind)
            server.enqueue(MockResponse().setBody("""{"choices":[]}"""))
            assertEquals(ApiFailure.Kind.malformed, failure { api.generate("hi", LocalData(), AppCategory.unknown, false, null, e, "k") }.kind)
            server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
            val timeout = failure { api.generate("hi", LocalData(), AppCategory.unknown, false, null, e, "k", sendTimeoutMs = { 300 }) }
            assertEquals(ApiFailure.Kind.timeout, timeout.kind); assertTrue(timeout.transient)
            server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
            val job = launch(Dispatchers.Default) { api.listModels(e, "k") }
            withContext(Dispatchers.IO) { while (server.requestCount < 4) Thread.sleep(10) }
            withTimeout(2000) { job.cancelAndJoin() }
            assertTrue(job.isCancelled)
        }
        val closed = MockWebServer().apply { start() }; val url = closed.url("/v1").toString(); closed.shutdown()
        val refused = failure { api.generate("hi", LocalData(), AppCategory.unknown, false, null, compatible(url).endpoint(), "k") }
        assertEquals(ApiFailure.Kind.offline, refused.kind); assertTrue(refused.transient)
        val noDns = ApiClient(OkHttpClient.Builder().dns(object : Dns { override fun lookup(hostname: String): List<InetAddress> = throw UnknownHostException(hostname) }).build())
        val offline = failure { noDns.generate("hi", LocalData(), AppCategory.unknown, false, null, compatible("https://offline.invalid/v1").endpoint(), "k") }
        assertEquals(ApiFailure.Kind.offline, offline.kind); assertTrue(offline.transient)
    }

    @Test fun cleartextReachesOnlyPrivateNetworksAndIsLabelledLocal() = runBlocking {
        for (base in listOf("http://192.168.1.20:11434/v1", "http://10.0.2.2:1234/v1", "http://127.0.0.1:11434/v1", "http://100.101.2.3/v1", "http://[fd00::1]/v1", "http://mypc.local:11434/v1")) {
            val e = compatible(base).endpoint(); assertTrue(base, e.local && e.cleartext)
        }
        for (base in listOf("http://8.8.8.8/v1", "http://[2001:4860::8888]/v1", "http://100.200.1.1/v1")) assertTrue(base, runCatching { canonicalBase(base) }.isFailure)
        assertFalse(compatible("https://api.example.com/v1").endpoint().local)
        assertTrue(compatible("https://192.168.1.5/v1").endpoint().local)
        // A hostname that resolves to the internet is refused before any connection (DNS rebinding).
        val publicDns = ApiClient(OkHttpClient.Builder().dns(object : Dns { override fun lookup(hostname: String) = listOf(InetAddress.getByName("8.8.8.8")) }).build())
        val refused = failure { publicDns.generate("hi", LocalData(), AppCategory.unknown, false, null, compatible("http://ollama.lan:11434/v1").endpoint(), "") }
        assertEquals(ApiFailure.Kind.setup, refused.kind); assertFalse(refused.transient)
    }

    private class Capture { val requests = CopyOnWriteArrayList<Request>() }
    private fun capturing(capture: Capture, body: (Request) -> String) = ApiClient(OkHttpClient.Builder().addInterceptor { chain ->
        capture.requests.add(chain.request())
        Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(body(chain.request()).toResponseBody("application/json".toMediaType())).build()
    }.build())
    private fun Request.json() = JSONObject(okio.Buffer().also { body!!.writeTo(it) }.readUtf8())

    @Test fun eachPresetUsesTheMacAddressHeadersAndRequestFormat() = runBlocking {
        val capture = Capture()
        val client = capturing(capture) { if (it.url.encodedPath.endsWith("/messages")) """{"stop_reason":"end_turn","content":[{"type":"text","text":"Hi."}]}""" else chat("Hi.") }
        val expected = mapOf(
            "anthropic" to "https://api.anthropic.com/v1/messages",
            "openai" to "https://api.openai.com/v1/chat/completions",
            "groq" to "https://api.groq.com/openai/v1/chat/completions",
            "gemini" to "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions",
            "openrouter" to "https://openrouter.ai/api/v1/chat/completions",
        )
        for ((id, url) in expected) {
            val e = Settings(provider = id, providers = if (id == "openrouter") mapOf(id to ProviderConfig("https://evil.test", "vendor/model")) else emptyMap()).endpoint()
            assertEquals("Hi.", client.generate("hi", LocalData(), AppCategory.unknown, false, null, e, "k-$id"))
            val r = capture.requests.last(); val body = r.json()
            assertEquals(url, r.url.toString()); assertEquals("POST", r.method)
            assertTrue(r.body!!.contentType().toString().startsWith("application/json"))
            for (absent in listOf("temperature", "stream", "tools")) assertFalse(body.has(absent))
            val messages = body.getJSONArray("messages")
            if (id == "anthropic") {
                assertEquals("k-anthropic", r.header("x-api-key")); assertEquals("2023-06-01", r.header("anthropic-version")); assertNull(r.header("Authorization"))
                assertEquals("claude-haiku-4-5", body.getString("model")); assertEquals(4096, body.getInt("max_tokens")); assertFalse(body.has("max_completion_tokens"))
                assertTrue(body.getString("system").contains("spoken formatting commands"))
                assertEquals(1, messages.length()); assertEquals("user", messages.getJSONObject(0).getString("role")); assertEquals("<transcript>\nhi", messages.getJSONObject(0).getString("content"))
            } else {
                assertEquals("Bearer k-$id", r.header("Authorization")); assertNull(r.header("x-api-key"))
                assertEquals(ProviderCatalog.find(id)!!.model.ifEmpty { "vendor/model" }, body.getString("model"))
                assertEquals(4096, body.getInt("max_completion_tokens")); assertFalse(body.has("max_tokens"))
                assertEquals("system", messages.getJSONObject(0).getString("role")); assertEquals("<transcript>\nhi", messages.getJSONObject(1).getString("content"))
            }
        }
        // Transforms give Anthropic 8192 output tokens; compatible stays 4096.
        client.generate("hi", LocalData(), AppCategory.unknown, false, "Rewrite", Settings().endpoint(), "k")
        assertEquals(8192, capture.requests.last().json().getInt("max_tokens"))
        // Custom servers may be keyless; cloud presets never send text without a key.
        client.generate("hi", LocalData(), AppCategory.unknown, false, null, compatible("https://local.example/v1").endpoint(), "")
        assertNull(capture.requests.last().header("Authorization"))
        val before = capture.requests.size
        for (id in expected.keys) assertEquals(ApiFailure.Kind.setup, failure { client.generate("hi", LocalData(), AppCategory.unknown, false, null, Settings(provider = id, providers = mapOf(id to ProviderConfig("", "m"))).endpoint(), "") }.kind)
        assertEquals(before, capture.requests.size)
    }

    @Test fun modelListingMatchesMacFilterAndBlankCustomModelUsesTheFirst() = runBlocking {
        MockWebServer().use { server ->
            val models = """{"data":[{"id":"whisper-large-v3"},{"id":"text-embedding-3"},{"id":"llama-guard-4"},{"id":"chat-a"},{"id":"TTS-1"},{"id":"chat-b"},{"id":"chat-a"}]}"""
            val e = compatible(server.url("/v1").toString(), model = "").endpoint()
            server.enqueue(MockResponse().setBody(models))
            assertEquals(listOf("chat-a", "chat-b"), api.listModels(e, "k"))
            server.takeRequest().let { assertEquals("GET", it.method); assertEquals("/v1/models", it.path); assertEquals("Bearer k", it.getHeader("Authorization")) }
            server.enqueue(MockResponse().setBody(models)); api.listModels(e, "")
            assertNull(server.takeRequest().getHeader("Authorization"))
            server.enqueue(MockResponse().setBody(models)); server.enqueue(MockResponse().setBody(chat("Hello.")))
            assertEquals("Hello.", api.generate("hi", LocalData(), AppCategory.unknown, false, null, e, ""))
            assertEquals("/v1/models", server.takeRequest().path)
            assertEquals("chat-a", JSONObject(server.takeRequest().body.readUtf8()).getString("model"))
            server.enqueue(MockResponse().setResponseCode(401))
            assertEquals(ApiFailure.Kind.invalidKey, failure { api.listModels(e, "bad") }.kind)
        }
    }

    @Test fun testConnectionSendsOneTinyRequestAndReportsTypedResults() = runBlocking {
        MockWebServer().use { server ->
            val e = compatible(server.url("/v1").toString()).endpoint()
            server.enqueue(MockResponse().setBody(chat("", "length")))
            api.testConnection(e, "k")
            val body = JSONObject(server.takeRequest().body.readUtf8())
            assertEquals(16, body.getInt("max_completion_tokens")); assertEquals("test-model", body.getString("model"))
            server.enqueue(MockResponse().setResponseCode(429).setBody("""{"error":{"code":"insufficient_quota"}}"""))
            val f = failure { api.testConnection(e, "k") }
            assertEquals(ApiFailure.Kind.quota, f.kind); assertEquals("HTTP 429 · insufficient_quota", f.detail)
            assertEquals(2, server.requestCount)
        }
    }

    private val xor = object : KeySealer {
        override fun seal(plain: ByteArray) = byteArrayOf(7) + plain.map { (it.toInt() xor 0x5a).toByte() }
        override fun open(sealed: ByteArray): ByteArray { require(sealed[0] == 7.toByte()); return sealed.drop(1).map { (it.toInt() xor 0x5a).toByte() }.toByteArray() }
    }

    @Test fun singleLegacyKeyMigratesToItsOwnScopeAndProvidersStayIsolated() {
        val root = Files.createTempDirectory("parla-keys").toFile()
        try {
            val openai = "openai-compatible|https://api.openai.com/v1"; val groq = "openai-compatible|https://api.groq.com/openai/v1"; val anthropic = "anthropic|https://api.anthropic.com/v1"
            val legacy = DurableFile(File(root, "provider-key.enc"))
            legacy.write(byteArrayOf(2) + xor.seal(JSONObject().put("scope", openai).put("key", "sk-openai").toString().toByteArray()))
            val keys = ProviderKeys(File(root, "provider-keys"), legacy, xor)
            assertTrue(keys.has(openai)); assertFalse(keys.has(groq)); assertFalse(keys.has(anthropic))
            assertEquals("sk-openai", keys.read(openai)); assertNull(keys.read(groq))
            assertFalse(legacy.baseFile.exists())
            keys.save(groq, "gsk-groq"); keys.save(anthropic, "sk-ant")
            assertEquals("sk-openai", keys.read(openai)); assertEquals("gsk-groq", keys.read(groq))
            keys.remove(openai)
            assertNull(keys.read(openai)); assertEquals("gsk-groq", keys.read(groq)); assertEquals("sk-ant", keys.read(anthropic))
            val files = File(root, "provider-keys").listFiles()!!
            assertEquals(2, files.size); assertTrue(files.none { String(it.readBytes()).contains("gsk-groq") || String(it.readBytes()).contains("sk-ant") })
            // A file moved to another scope's name is refused, never sent to that address.
            fun file(scope: String) = File(File(root, "provider-keys"), java.security.MessageDigest.getInstance("SHA-256").digest(scope.toByteArray()).joinToString("") { "%02x".format(it) } + ".key")
            file(groq).copyTo(file(anthropic), overwrite = true)
            assertTrue(runCatching { keys.read(anthropic) }.exceptionOrNull() is IllegalStateException)
        } finally { root.deleteRecursively() }
    }

    @Test fun legacyMigrationKeepsNewerKeyAndUnboundKeyNeedsExplicitSave() {
        val root = Files.createTempDirectory("parla-keys").toFile()
        try {
            val scope = "openai-compatible|https://api.openai.com/v1"
            val legacy = DurableFile(File(root, "provider-key.enc"))
            ProviderKeys(File(root, "provider-keys"), DurableFile(File(root, "none")), xor).save(scope, "newer")
            legacy.write(byteArrayOf(2) + xor.seal(JSONObject().put("scope", scope).put("key", "older").toString().toByteArray()))
            assertEquals("newer", ProviderKeys(File(root, "provider-keys"), legacy, xor).read(scope)); assertFalse(legacy.baseFile.exists())
            legacy.write(byteArrayOf(1) + xor.seal("unbound".toByteArray()))
            val keys = ProviderKeys(File(root, "provider-keys2"), legacy, xor)
            assertFalse(keys.has(scope)); assertNull(keys.read(scope)); assertTrue(legacy.baseFile.exists())
            assertTrue(keys.adoptLegacy(scope)); assertEquals("unbound", keys.read(scope)); assertFalse(legacy.baseFile.exists())
        } finally { root.deleteRecursively() }
    }

    @Test fun oldSchemasMigrateToNamedPresetsWithTheSameKeyScope() {
        fun v4(provider: String, base: String, model: String) = JSONObject().put("version", 4).put("settings", JSONObject()
            .put("accessibilityConsentGranted", false).put("recoveryAudioEnabled", false).put("recoveryAudioDays", 7)
            .put("provider", provider).put("baseUrl", base).put("cleanupModel", model)).toString()
        val groq = LocalDataCodec.decode(v4("openai-compatible", "https://api.groq.com/openai/v1/", "openai/gpt-oss-20b")).settings
        assertEquals("groq", groq.provider); assertEquals("openai/gpt-oss-20b", groq.endpoint().model)
        assertEquals("openai-compatible|https://api.groq.com/openai/v1", groq.endpoint().scope)
        val custom = LocalDataCodec.decode(v4("openai-compatible", "https://Proxy.example/v1/", "m")).settings
        assertEquals("custom", custom.provider); assertEquals("openai-compatible|https://proxy.example/v1", custom.endpoint().scope)
        val anthropic = LocalDataCodec.decode(v4("anthropic", "https://api.anthropic.com/v1", "claude-sonnet-5")).settings
        assertEquals("anthropic", anthropic.provider); assertEquals("claude-sonnet-5", anthropic.endpoint().model)
        val v1 = LocalDataCodec.decode("""{"version":1,"settings":{}}""").settings
        assertEquals("openai", v1.provider); assertEquals("gpt-4.1-mini", v1.endpoint().model)
        assertEquals("apple-intelligence", LocalDataCodec.decode(v4("apple-intelligence", "https://api.anthropic.com/v1", "x")).settings.provider)
        // Schema 5 round trip keeps every provider's configuration and the backup chain.
        val s = Settings(provider = "openai", providers = mapOf("openai" to ProviderConfig("https://api.openai.com/v1", "gpt-5-mini"), "groq" to ProviderConfig("https://api.groq.com/openai/v1", "g"), "custom" to ProviderConfig("http://192.168.1.2:11434/v1", "")),
            backups = listOf(CleanupBackup("groq", "https://api.groq.com/openai/v1", "g"), CleanupBackup("custom", "http://192.168.1.2:11434/v1", "llama3.1", keyless = true)), backupReview = "abc")
        assertEquals(s, LocalDataCodec.decode(LocalDataCodec.encode(LocalData(s))).settings)
        assertEquals("g", s.copy(provider = "groq").endpoint().model); assertEquals("gpt-5-mini", s.endpoint().model)
        val three = JSONObject(LocalDataCodec.encode(LocalData(s))).apply { getJSONObject("settings").getJSONArray("backups").put(JSONObject().put("provider", "openai").put("baseUrl", "").put("model", "m").put("keyless", false)) }
        assertTrue(runCatching { LocalDataCodec.decode(three.toString()) }.isFailure)
        assertTrue(runCatching { LocalDataCodec.decode(LocalDataCodec.encode(LocalData(s.copy(provider = "vendor")))) }.isFailure)
    }

    @Test fun pipelineAsksOnlyForTheSelectedProvidersKey() = runBlocking {
        val capture = Capture(); val asked = mutableListOf<String>()
        val pipeline = Pipeline(capturing(capture) { chat("Hello.") })
        val data = LocalData(Settings(provider = "groq", providers = mapOf("openai" to ProviderConfig("", "gpt-4.1-mini"))))
        assertEquals("Hello.", pipeline.clean("hello", data) { scope -> asked += scope; if (scope.endsWith("groq.com/openai/v1")) "gsk" else "WRONG" }.text)
        assertEquals(listOf("openai-compatible|https://api.groq.com/openai/v1"), asked)
        assertEquals("Bearer gsk", capture.requests.single().header("Authorization"))
        val locked = pipeline.clean("hello", data) { throw IllegalStateException("AI cleanup is paused. Reload or repair saved data.") }
        assertTrue(locked.warning!!.startsWith("AI cleanup is paused"))
    }

    /** Primary at /a, backups at /b and /c on one mock server; each path is its own address and key scope. */
    private class Chain(val server: MockWebServer, val respond: (String) -> MockResponse) {
        val hits = CopyOnWriteArrayList<String>()
        init { server.dispatcher = object : Dispatcher() { override fun dispatch(request: RecordedRequest): MockResponse { val p = request.path!!.substring(1, 2); hits += p; return respond(p) } } }
        fun settings(backups: Int = 2): Settings {
            val s = compatible(server.url("/a/v1").toString(), "primary").copy(backups = listOf("b", "c").take(backups).map { CleanupBackup("custom", server.url("/$it/v1").toString(), "model-$it", keyless = true) })
            return s.copy(backupReview = CleanupFailover.digest(s))
        }
    }
    private fun chain(respond: (String) -> MockResponse, block: suspend (Chain) -> Unit) = runBlocking { MockWebServer().use { block(Chain(it, respond)) } }

    @Test fun transientPrimaryFailureAdvancesToReviewedBackups() = chain({ p -> if (p == "c") MockResponse().setBody(chat("Hello there.")) else MockResponse().setResponseCode(if (p == "a") 503 else 429) }) { c ->
        val result = Pipeline(api).dictate("hello there", LocalData(c.settings())) { "" }
        assertNull(result.warning); assertEquals("Hello there.", result.text); assertEquals(listOf("a", "b", "c"), c.hits)
    }

    @Test fun authenticationContentAndConfigurationErrorsStopTheChain() {
        for (response in listOf(MockResponse().setResponseCode(401), MockResponse().setResponseCode(403),
            MockResponse().setResponseCode(400).setBody("""{"error":{"code":"model_not_found"}}"""),
            MockResponse().setResponseCode(500).setBody("""{"error":{"type":"invalid_request_error"}}"""),
            MockResponse().setBody(chat("partial", "content_filter")), MockResponse().setBody("{broken"))) {
            chain({ p -> if (p == "a") response else MockResponse().setBody(chat("backup")) }) { c ->
                val result = Pipeline(api).dictate("hello", LocalData(c.settings())) { "" }
                assertEquals("hello", result.text); assertNotNull(result.warning); assertEquals(listOf("a"), c.hits)
            }
        }
    }

    @Test fun backupsNeedReviewOrdinaryDictationAndNeverShopForOutput() = chain({ p -> if (p == "a") MockResponse().setResponseCode(503) else MockResponse().setBody(chat("x".repeat(500))) }) { c ->
        val reviewed = c.settings()
        assertTrue(CleanupFailover.isReviewed(reviewed))
        for (data in listOf(reviewed.copy(backupReview = ""), reviewed.copy(providers = mapOf("custom" to reviewed.active.copy(model = "edited"))),
                reviewed.copy(backups = reviewed.backups.reversed()))) assertFalse(CleanupFailover.isReviewed(data))
        Pipeline(api).dictate("hello", LocalData(reviewed.copy(backupReview = ""))) { "" }
        Pipeline(api).clean("hello", LocalData(reviewed)) { "" } // history retry: failover off
        val preset = TransformPreset(name = "Rewrite", instruction = "Be brief")
        Pipeline(api).dictate("hello", LocalData(reviewed.copy(outputMode = "selectedPreset", selectedPresetID = preset.id), presets = listOf(preset))) { "" }
        assertEquals(listOf("a", "a", "a"), c.hits)
        // The first returned text is final: invalid backup output keeps the original, the next backup is not tried.
        c.hits.clear()
        val result = Pipeline(api).dictate("hello", LocalData(reviewed)) { "" }
        assertEquals("hello", result.text); assertTrue(result.warning!!.contains("invalid")); assertEquals(listOf("a", "b"), c.hits)
        assertTrue(runCatching { CleanupFailover.chain(reviewed.copy(backups = reviewed.backups + CleanupBackup("openai", "", "m"))) }.isFailure)
        assertTrue(runCatching { CleanupFailover.chain(reviewed.copy(backups = listOf(CleanupBackup("openai", "", "m", keyless = true)))) }.isFailure)
        assertTrue(runCatching { CleanupFailover.chain(reviewed.copy(backups = listOf(CleanupBackup("custom", reviewed.active.baseUrl, "primary", keyless = true)))) }.isFailure)
    }

    @Test fun backupsShareOneFifteenSecondBudgetAndNeedThreeSecondsToStart() = runBlocking {
        val e = compatible("https://example.test/v1").endpoint(); val chain = listOf(e, e.copy(model = "b"), e.copy(model = "c"))
        val now = AtomicLong(0); val seen = mutableListOf<Long>()
        suspend fun run(costs: List<Long>, failure: ApiFailure = httpFailure(503, null, null)) = runCatching {
            CleanupFailover.run(chain, now::get) { i, _, timeout -> seen += timeout(); now.addAndGet(costs[i]); throw failure }
        }.exceptionOrNull()
        assertSame(httpFailure(503, null, null).kind, (run(listOf(4000, 8000, 0)) as ApiFailure).kind)
        assertEquals(listOf(15000L, 11000L, 3000L), seen) // exactly 3 s left still starts
        seen.clear(); now.set(0); run(listOf(12001, 0, 0)); assertEquals(listOf(15000L), seen)
        seen.clear(); now.set(0); run(listOf(0, 0, 0), httpFailure(401, null, null)); assertEquals(listOf(15000L), seen)
        seen.clear(); now.set(0)
        val canceled = runCatching { CleanupFailover.run(chain, now::get) { _, _, r -> seen += r(); throw CancellationException("stop") } }.exceptionOrNull()
        assertTrue(canceled is CancellationException); assertEquals(1, seen.size)
        // Each attempt's HTTP timeout is the remaining shared budget.
        MockWebServer().use { server ->
            server.dispatcher = object : Dispatcher() { override fun dispatch(request: RecordedRequest) = if (request.path!!.startsWith("/a")) MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE) else MockResponse().setBody(chat("late")) }
            val s = compatible(server.url("/a/v1").toString(), "primary").copy(backups = listOf(CleanupBackup("custom", server.url("/b/v1").toString(), "b", keyless = true)))
            val clock = AtomicLong(0)
            val started = System.nanoTime()
            // The fake clock says 14.8 s are gone, so the primary gets 200 ms and no backup may start.
            val result = Pipeline(api) { clock.getAndSet(14_800) }.dictate("hello", LocalData(s.copy(backupReview = CleanupFailover.digest(s)))) { "" }
            assertTrue(result.warning!!.contains("too long")); assertEquals(1, server.requestCount)
            assertTrue(System.nanoTime() - started < 5_000_000_000)
        }
    }

    // Review round 1 (B1-B5).
    private suspend fun Pipeline.dictate(raw: String, data: LocalData, live: StateFlow<LocalData> = MutableStateFlow(data), key: (String) -> String) =
        clean(raw, data, failover = live, key = key)

    @Test fun backupKeyDraftFollowsTheDestinationNotTheRow() { // B1
        val openai = CleanupBackup("openai", "", "gpt-4.1-mini").endpoint(); val groq = CleanupBackup("groq", "", "openai/gpt-oss-120b").endpoint()
        val drafts = mapOf(openai.scope to "sk-openai-draft")
        assertEquals("sk-openai-draft", drafts.draftFor(openai))
        assertEquals("", drafts.draftFor(groq)) // the row now points at Groq: nothing to save there
        assertEquals("", drafts.draftFor(null))
    }

    @Test fun savingUsesTheCapturedEndpointForProviderAndConfiguration() { // B2
        val current = Settings(provider = "anthropic", providers = mapOf("groq" to ProviderConfig("https://api.groq.com/openai/v1", "g")))
        val captured = Settings(provider = "openai", providers = mapOf("openai" to ProviderConfig("", "gpt-5-mini"))).endpoint()
        val saved = current.withConnection(captured)
        assertEquals("openai", saved.provider); assertEquals("gpt-5-mini", saved.endpoint().model)
        assertEquals(captured.scope, saved.endpoint().scope); assertEquals("g", saved.providers.getValue("groq").model)
    }

    @Test fun revokingBackupsMidFlightStopsAndCancelsThem() { // B3
        val live = MutableStateFlow(LocalData())
        fun revoke() { live.value = live.value.copy(settings = live.value.settings.copy(backupReview = "")) }
        // Turned off while the primary is pending: the later transient failure must not reach a backup.
        chain({ p -> if (p == "a") { revoke(); MockResponse().setResponseCode(503) } else MockResponse().setBody(chat("backup")) }) { c ->
            live.value = LocalData(c.settings())
            val result = Pipeline(api).dictate("hello", live.value, live) { "" }
            assertEquals("hello", result.text); assertTrue(result.warning!!.contains("turned off")); assertEquals(listOf("a"), c.hits)
        }
        // Turned off while a backup is in flight: the call is canceled, not awaited.
        chain({ p -> if (p == "a") MockResponse().setResponseCode(503) else { revoke(); MockResponse().setHeadersDelay(2, TimeUnit.SECONDS).setBody(chat("late backup")) } }) { c ->
            live.value = LocalData(c.settings())
            val started = System.nanoTime()
            val result = Pipeline(api).dictate("late backup", live.value, live) { "" }
            assertEquals("late backup", result.text); assertTrue(result.warning!!.contains("turned off")); assertEquals(listOf("a", "b"), c.hits)
            assertTrue(System.nanoTime() - started < 1_500_000_000)
        }
    }

    @Test fun lateBackupAdmissionAndLateSuccessAreRefused() = runBlocking { // B4
        val now = AtomicLong(0); val sent = CopyOnWriteArrayList<Pair<String, Long>>()
        var backupCost = 0L
        val client = ApiClient(OkHttpClient.Builder().addInterceptor { chain ->
            val host = chain.request().url.host
            sent += host to chain.call().timeout().timeoutNanos() / 1_000_000
            now.addAndGet(if (host == "a.test") 11_900 else backupCost)
            Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(if (host == "a.test") 503 else 200).message("x")
                .body(chat("Hello there.").toResponseBody("application/json".toMediaType())).build()
        }.build())
        val unreviewed = compatible("https://a.test/v1", "primary").copy(backups = listOf(CleanupBackup("custom", "https://b.test/v1", "mb")))
        val s = unreviewed.copy(backupReview = CleanupFailover.digest(unreviewed))
        suspend fun dictate(keyCost: Long): CleanupResult {
            now.set(0); sent.clear()
            return Pipeline(client, now::get).dictate("hello there", LocalData(s)) { scope -> if (scope.contains("b.test")) now.addAndGet(keyCost); "k" }
        }
        // Admitted with 3.1 s left, 0.2 s spent reading the key: under 3 s at send, so nothing is sent.
        assertNotNull(dictate(200).warning); assertEquals(listOf("a.test" to 15_000L), sent)
        // 0.1 s preparing: sent, and its timeout is the 3.0 s left at send, not 3.1 s.
        assertEquals("Hello there.", dictate(100).text); assertEquals(listOf("a.test" to 15_000L, "b.test" to 3_000L), sent)
        // A backup result arriving after the shared deadline is rejected.
        backupCost = 3_500
        val late = dictate(0); assertEquals("hello there", late.text); assertTrue(late.warning!!.contains("too long"))
    }

    @Test fun localCleartextClientNeverUsesAProxy() = runBlocking { // B5
        MockWebServer().use { proxy ->
            proxy.enqueue(MockResponse().setBody(chat("via proxy")))
            val closed = MockWebServer().apply { start() }; val port = closed.port; closed.shutdown()
            val proxied = ApiClient(OkHttpClient.Builder().proxy(Proxy(Proxy.Type.HTTP, InetSocketAddress(proxy.hostName, proxy.port))).build())
            assertEquals(Proxy.NO_PROXY, proxied.cleartext.proxy)
            val f = failure { proxied.generate("hi", LocalData(), AppCategory.unknown, false, null, compatible("http://127.0.0.1:$port/v1").endpoint(), "k") }
            assertEquals(ApiFailure.Kind.offline, f.kind); assertEquals(0, proxy.requestCount)
        }
    }
}
