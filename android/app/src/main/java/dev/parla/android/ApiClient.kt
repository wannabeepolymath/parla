package dev.parla.android

import java.io.IOException
import java.io.InterruptedIOException
import java.net.Proxy
import java.net.SocketException
import java.net.UnknownHostException
import java.net.UnknownServiceException
import java.util.concurrent.TimeUnit
import javax.net.ssl.SSLException
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import org.json.JSONTokener

/**
 * Every message is a fixed string: provider bodies, `error.message` and keys never reach the UI.
 * [code] and [type] keep only allowlisted provider values.
 */
class ApiFailure(message: String, val kind: Kind = Kind.other, val status: Int? = null, val code: String? = null, val type: String? = null) : IOException(message) {
    enum class Kind { setup, invalidKey, expiredKey, noAccess, modelNotFound, badRequest, tooLarge, timeout, offline, rateLimited, quota, unavailable, redirect, malformed, refused, other }
    /** Mac cleanupFailoverMayProceed: network loss, timeout, or 408/429/5xx without a semantic stop. */
    val transient: Boolean get() = when {
        status == null -> kind == Kind.timeout || kind == Kind.offline
        status == 401 || status == 403 || code in STOP_CODES || type in STOP_CODES -> false
        else -> status == 408 || status == 429 || status in 500..599
    }
    /** Safe detail for Test connection: status and allowlisted codes only. */
    val detail: String? get() = listOfNotNull(status?.let { "HTTP $it" }, code, type?.takeIf { it != code }).joinToString(" · ").ifEmpty { null }
    internal companion object {
        val STOP_CODES = setOf("expired_api_key", "invalid_api_key", "authentication_error", "permission_error",
            "content_filter", "content_policy_violation", "invalid_prompt", "refusal", "invalid_request_error", "not_found_error", "model_not_found")
        val KNOWN_CODES = STOP_CODES + setOf("insufficient_quota", "rate_limit_exceeded", "rate_limit_error", "overloaded_error",
            "api_error", "server_error", "request_too_large", "context_length_exceeded")
    }
}

internal fun httpFailure(status: Int, rawCode: String?, rawType: String?): ApiFailure {
    val code = rawCode?.takeIf { it in ApiFailure.KNOWN_CODES }; val type = rawType?.takeIf { it in ApiFailure.KNOWN_CODES }
    fun has(vararg values: String) = values.any { it == code || it == type }
    val (kind, message) = when {
        has("expired_api_key") -> ApiFailure.Kind.expiredKey to "Your API key has expired. Create a new key with your provider and save it in API connection."
        status == 401 || has("invalid_api_key", "authentication_error") -> ApiFailure.Kind.invalidKey to "The provider didn't accept your API key. Check it and save it again in API connection."
        status == 403 || has("permission_error") -> ApiFailure.Kind.noAccess to "Your API key doesn't have access to this model. Check your provider account or choose another model."
        status == 404 || has("model_not_found", "not_found_error") -> ApiFailure.Kind.modelNotFound to "The provider couldn't find this model or address. Check the model ID and API address."
        status == 408 -> ApiFailure.Kind.timeout to PROVIDER_TIMEOUT
        status == 413 || has("request_too_large", "context_length_exceeded") -> ApiFailure.Kind.tooLarge to "Text is too long for the provider. Try a shorter dictation."
        status == 402 || has("insufficient_quota") -> ApiFailure.Kind.quota to "Your provider account is out of credits or quota. Check billing with your provider."
        status == 429 -> ApiFailure.Kind.rateLimited to "The provider is limiting requests right now. Wait a moment and try again."
        has("content_filter", "content_policy_violation", "invalid_prompt", "refusal") -> ApiFailure.Kind.refused to "The provider declined to process this text."
        status in 500..599 -> ApiFailure.Kind.unavailable to "The provider is unavailable right now. Try again shortly."
        status in 300..399 -> ApiFailure.Kind.redirect to "The provider redirected the request. Save its direct API address."
        status == 400 -> ApiFailure.Kind.badRequest to "The provider rejected the request. Check the model ID and API settings."
        else -> ApiFailure.Kind.other to "Provider request failed (HTTP $status). Try again or check API settings."
    }
    return ApiFailure(message, kind, status, code, type)
}
internal const val PROVIDER_TIMEOUT = "The provider took too long to respond. Try again."
private val MALFORMED get() = ApiFailure("The provider sent a response Parla couldn't read. Try again or check the model.", ApiFailure.Kind.malformed)

internal fun transportFailure(e: IOException): ApiFailure = when (e) {
    is ApiFailure -> e
    is InterruptedIOException -> ApiFailure(PROVIDER_TIMEOUT, ApiFailure.Kind.timeout) // socket and OkHttp call timeouts
    is UnknownHostException, is SocketException -> ApiFailure("Couldn't reach the provider. Check your internet connection, or that your local server is running.", ApiFailure.Kind.offline)
    is UnknownServiceException -> ApiFailure(PUBLIC_CLEARTEXT, ApiFailure.Kind.setup)
    is SSLException -> ApiFailure("A secure connection to the provider couldn't be made. Check the API address.")
    else -> ApiFailure("The connection to the provider failed. Try again.")
}

/** Mac CleanupUsageSink: response model (else the requested one) and reported tokens; null = not reported. */
data class CleanupUsage(val model: String, val input: Int?, val output: Int?)
internal data class Generated(val text: String, val usage: CleanupUsage)

/**
 * Anthropic `usage.input_tokens`/`output_tokens`, OpenAI-compatible `usage.prompt_tokens`/`completion_tokens`.
 * ponytail: a malformed usage value is unknown, never a failed cleanup (Mac's decoder would reject the response).
 */
internal fun responseUsage(json: JSONObject, anthropic: Boolean, requested: String, key: String): CleanupUsage {
    val usage = json.optJSONObject("usage")
    fun tokens(name: String) = (usage?.opt(name) as? Number)?.takeIf { it is Int || it is Long }?.toLong()?.takeIf { it in 0..Int.MAX_VALUE }?.toInt()
    val reported = (json.opt("model") as? String)?.takeIf { m -> m.isNotEmpty() && m.toByteArray().size <= 160 && m.none { it.isISOControl() } }
    val model = (reported ?: requested).let { if(key.isEmpty()) it else it.replace(key, "[redacted]") }
    return if(anthropic) CleanupUsage(model, tokens("input_tokens"), tokens("output_tokens"))
        else CleanupUsage(model, tokens("prompt_tokens"), tokens("completion_tokens"))
}

/** Optional text-only transport. Model downloads have a separate unauthenticated client. */
class ApiClient(client: OkHttpClient = OkHttpClient()) {
    // No silent retries: OkHttp would otherwise resend the transcript on 408 or a dropped connection.
    private val transport = client.newBuilder().followRedirects(false).followSslRedirects(false).retryOnConnectionFailure(false)
        .callTimeout(15, TimeUnit.SECONDS).connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS).writeTimeout(15, TimeUnit.SECONDS).build()
    // http:// is allowed only when every resolved address is on a private network (no DNS rebinding to the internet).
    // Never via a proxy: a proxy would receive the request for any host, bypassing the private-address check.
    internal val cleartext = transport.newBuilder().proxy(Proxy.NO_PROXY).dns(object : Dns { override fun lookup(hostname: String) =
        transport.dns.lookup(hostname).also { if (it.isEmpty() || !it.all(::isPrivateAddress)) throw ApiFailure(PUBLIC_CLEARTEXT, ApiFailure.Kind.setup) } }).build()

    internal suspend fun generate(source: String, data: LocalData, category: AppCategory, singleLine: Boolean, instruction: String?,
                                  endpoint: Endpoint, key: String, sendTimeoutMs: () -> Long = { TIMEOUT_MS }): String =
        generateWithUsage(source, data, category, singleLine, instruction, endpoint, key, sendTimeoutMs).text

    internal suspend fun generateWithUsage(source: String, data: LocalData, category: AppCategory, singleLine: Boolean, instruction: String?,
                                           endpoint: Endpoint, key: String, sendTimeoutMs: () -> Long = { TIMEOUT_MS }): Generated {
        requireKey(endpoint, key)
        val system = PromptBuilder.system(data, category, singleLine, instruction != null)
        val user = PromptBuilder.user(source, instruction)
        // Mac OpenAICompatClient: a blank custom model uses the server's first chat model.
        val model = endpoint.model.ifEmpty { if (endpoint.custom) listModels(endpoint, key).firstOrNull() ?: throw ApiFailure("The server listed no chat model. Enter a model ID in API connection.", ApiFailure.Kind.setup) else throw ApiFailure("Choose a text cleanup model in API connection.", ApiFailure.Kind.setup) }
        val json = complete(endpoint, model, key, system, user, if (endpoint.anthropic && instruction != null) 8192 else 4096, sendTimeoutMs)
        // ponytail: usage rides only an accepted result; a truncated or refused reply's tokens are not recorded.
        val usage = responseUsage(json, endpoint.anthropic, model, key)
        return try {
            Generated(if (endpoint.anthropic) {
                if (json.optString("stop_reason") in setOf("max_tokens", "model_context_window_exceeded", "refusal")) throw ApiFailure("Cleanup was truncated or refused.", ApiFailure.Kind.refused)
                val blocks = json.getJSONArray("content")
                (0 until blocks.length()).map { blocks.getJSONObject(it) }.filter { it.optString("type") == "text" }.joinToString("") { it.getString("text") }
            } else {
                val choice = json.getJSONArray("choices").getJSONObject(0)
                val message = choice.getJSONObject("message")
                if (choice.optString("finish_reason") in setOf("length", "content_filter") || (!message.isNull("refusal") && message.optString("refusal").isNotEmpty())) throw ApiFailure("Cleanup was truncated or refused.", ApiFailure.Kind.refused)
                when (val content = message.opt("content")) {
                    is String -> content
                    is JSONArray -> (0 until content.length()).joinToString("") { content.getJSONObject(it).optString("text") }
                    else -> throw ApiFailure("Cleanup returned no text", ApiFailure.Kind.malformed)
                }
            }, usage)
        } catch (e: org.json.JSONException) { throw MALFORMED }
    }

    /** Test connection: a tiny real request in the same format. Success means the provider accepted key, model and shape. */
    internal suspend fun testConnection(endpoint: Endpoint, key: String) {
        requireKey(endpoint, key)
        val model = endpoint.model.ifEmpty { if (endpoint.custom) listModels(endpoint, key).firstOrNull() ?: throw ApiFailure("The server listed no chat model.", ApiFailure.Kind.setup) else throw ApiFailure("Choose a model first.", ApiFailure.Kind.setup) }
        val json = complete(endpoint, model, key, "Reply with OK.", "OK", 16) { TIMEOUT_MS }
        if (!json.has(if (endpoint.anthropic) "content" else "choices")) throw MALFORMED
    }

    /** Mac firstServerModel: GET {base}/models, optional Bearer, non-chat families filtered, server order kept. */
    internal suspend fun listModels(endpoint: Endpoint, key: String): List<String> {
        if (endpoint.anthropic) throw ApiFailure("Enter an Anthropic model ID.", ApiFailure.Kind.setup)
        validateProviderKey(key)
        val request = Request.Builder().url(url(endpoint, "models")).get()
        if (key.isNotBlank()) request.header("Authorization", "Bearer $key")
        val data = parse(execute(request.build(), TIMEOUT_MS, MAX_LIST_BYTES)).optJSONArray("data") ?: throw MALFORMED
        return (0 until data.length()).mapNotNull { data.optJSONObject(it)?.opt("id") as? String }
            .filter { id -> NON_CHAT.none { id.lowercase().contains(it) } }.distinct().take(1000)
    }

    private fun requireKey(endpoint: Endpoint, key: String) {
        validateProviderKey(key)
        // Only custom servers may be keyless (local Ollama, LM Studio). Cloud presets never receive text unauthenticated.
        if (key.isBlank() && !endpoint.custom) throw ApiFailure("Save an API key for ${endpoint.label} in API connection to use AI cleanup.", ApiFailure.Kind.setup)
    }
    private fun url(endpoint: Endpoint, path: String) = (endpoint.baseUrl + "/" + path).toHttpUrlOrNull() ?: throw ApiFailure("Enter a valid API address.", ApiFailure.Kind.setup)

    private suspend fun complete(endpoint: Endpoint, model: String, key: String, system: String, user: String, maxTokens: Int, sendTimeoutMs: () -> Long): JSONObject {
        val body = JSONObject().put("model", model)
        val messages = JSONArray()
        if (endpoint.anthropic) body.put("max_tokens", maxTokens).put("system", system)
        else { body.put("max_completion_tokens", maxTokens); messages.put(JSONObject().put("role", "system").put("content", system)) }
        messages.put(JSONObject().put("role", "user").put("content", user)); body.put("messages", messages)
        val request = Request.Builder().url(url(endpoint, if (endpoint.anthropic) "messages" else "chat/completions"))
            .post(body.toString().toRequestBody("application/json".toMediaType()))
        if (endpoint.anthropic) request.header("x-api-key", key).header("anthropic-version", "2023-06-01")
        else if (key.isNotBlank()) request.header("Authorization", "Bearer $key")
        // Evaluated at the moment of sending: it may refuse a late backup, and it bounds the call by what remains.
        return parse(execute(request.build(), sendTimeoutMs(), MAX_RESPONSE_BYTES))
    }
    private fun parse(text: String): JSONObject = try { JSONObject(text) } catch (_: org.json.JSONException) { throw MALFORMED }

    private suspend fun execute(request: Request, timeoutMs: Long, limit: Int): String = suspendCancellableCoroutine { continuation ->
        val call = (if (request.url.isHttps) transport else cleartext).newCall(request)
        call.timeout().timeout(timeoutMs.coerceAtLeast(1), TimeUnit.MILLISECONDS)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(transportFailure(e))
            }
            override fun onResponse(call: Call, response: Response) {
                try {
                    val result = response.use {
                        if (!it.isSuccessful) throw errorFor(it)
                        val body = it.body ?: throw ApiFailure("The provider returned an empty response.", ApiFailure.Kind.malformed)
                        body.byteStream().use { stream ->
                            val bytes = stream.readNBytes(limit + 1)
                            if (bytes.size > limit) throw ApiFailure("The provider response was too large.", ApiFailure.Kind.malformed)
                            bytes.toString(Charsets.UTF_8)
                        }
                    }
                    if (continuation.isActive) continuation.resume(result)
                } catch (failure: Exception) {
                    if (continuation.isActive) continuation.resumeWithException(when (failure) {
                        is ApiFailure -> failure
                        is IOException -> transportFailure(failure)
                        else -> MALFORMED
                    })
                }
            }
        })
    }
    /** Reads at most 16 KiB of the error envelope and keeps only `error.code` / `error.type`. */
    private fun errorFor(response: Response): ApiFailure {
        val error = runCatching {
            val text = response.body?.byteStream()?.use { it.readNBytes(MAX_ERROR_BYTES) }?.toString(Charsets.UTF_8).orEmpty()
            when (val root = JSONTokener(text).nextValue()) {
                is JSONObject -> root
                is JSONArray -> root.optJSONObject(0) // Gemini wraps errors in an array.
                else -> null
            }?.optJSONObject("error")
        }.getOrNull()
        return httpFailure(response.code, error?.opt("code") as? String, error?.opt("type") as? String)
    }

    internal companion object {
        const val TIMEOUT_MS = 15_000L
        const val MAX_RESPONSE_BYTES = 2 * 1024 * 1024
        const val MAX_LIST_BYTES = 8 * 1024 * 1024 // OpenRouter's catalog is large.
        const val MAX_ERROR_BYTES = 16 * 1024
        val NON_CHAT = listOf("whisper", "tts", "embed", "guard", "moderation", "rerank", "audio", "orpheus")
    }
}

internal fun validateProviderKey(key: String) {
    if (key.length > 8192 || key.any { it.code !in 33..126 }) {
        throw ApiFailure("The API key contains unsupported characters. Re-enter it using printable ASCII without spaces.", ApiFailure.Kind.setup)
    }
}
