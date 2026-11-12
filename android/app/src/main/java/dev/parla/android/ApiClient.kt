package dev.parla.android

import java.io.IOException
import java.util.concurrent.TimeUnit
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.suspendCancellableCoroutine
import okhttp3.*
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject

class ApiFailure(message: String) : IOException(message)

/** Optional text-only transport. Model downloads have a separate unauthenticated client. */
class ApiClient(client: OkHttpClient = OkHttpClient(), private val allowInsecureLocalhostForTests: Boolean = false) {
    private val transport = client.newBuilder().followRedirects(false).followSslRedirects(false)
        .callTimeout(15, TimeUnit.SECONDS).connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(15, TimeUnit.SECONDS).writeTimeout(15, TimeUnit.SECONDS).build()

    suspend fun generate(source: String, data: LocalData, category: AppCategory, singleLine: Boolean, instruction: String?, key: String): String {
        val s = data.settings
        if (s.provider == "apple-intelligence") throw ApiFailure("Apple Intelligence is unavailable on Android. Choose a remote text provider explicitly.")
        if (s.provider == "anthropic" && key.isBlank()) throw ApiFailure("Optional text cleanup needs a saved key for this provider endpoint.")
        validateProviderKey(key)
        val anthropic = s.provider == "anthropic"
        if (!anthropic && s.provider != "openai-compatible") throw ApiFailure("Unsupported text provider.")
        val base = canonicalEndpoint(s, allowInsecureLocalhostForTests).toHttpUrlOrNull() ?: throw ApiFailure("Invalid endpoint")
        val url = base.newBuilder().addPathSegments(if(anthropic) "messages" else "chat/completions").build()
        val system = PromptBuilder.system(data, category, singleLine, instruction != null)
        val user = PromptBuilder.user(source, instruction)
        val body = JSONObject().put("model", s.cleanupModel.trim().ifEmpty { throw ApiFailure("Choose a text cleanup model.") })
        val messages = JSONArray()
        if (anthropic) body.put("system", system).put("max_tokens", if(instruction == null) 4096 else 8192)
        else { body.put("max_completion_tokens",4096); messages.put(JSONObject().put("role", "system").put("content", system)) }
        messages.put(JSONObject().put("role", "user").put("content", user)); body.put("messages", messages)
        val request = Request.Builder().url(url).post(body.toString().toRequestBody("application/json".toMediaType()))
        if(anthropic) request.header("x-api-key", key).header("anthropic-version", "2023-06-01") else if(key.isNotBlank()) request.header("Authorization", "Bearer $key")
        val json = JSONObject(execute(request.build()))
        return if(anthropic) {
            if(json.optString("stop_reason") in setOf("max_tokens", "model_context_window_exceeded", "refusal")) throw ApiFailure("Cleanup was truncated or refused.")
            val blocks = json.getJSONArray("content")
            (0 until blocks.length()).map { blocks.getJSONObject(it) }.filter { it.optString("type") == "text" }.joinToString("") { it.getString("text") }
        } else {
            val choice = json.getJSONArray("choices").getJSONObject(0)
            val message = choice.getJSONObject("message")
            if(choice.optString("finish_reason") in setOf("length", "content_filter") || (!message.isNull("refusal") && message.optString("refusal").isNotEmpty())) throw ApiFailure("Cleanup was truncated or refused.")
            when(val content = message.opt("content")) {
                is String -> content
                is JSONArray -> (0 until content.length()).joinToString("") { content.getJSONObject(it).optString("text") }
                else -> throw ApiFailure("Cleanup returned no text")
            }
        }
    }
    private suspend fun execute(request: Request): String = suspendCancellableCoroutine { continuation ->
        val call = transport.newCall(request)
        continuation.invokeOnCancellation { call.cancel() }
        call.enqueue(object : Callback {
            override fun onFailure(call: Call, e: IOException) {
                if (continuation.isActive) continuation.resumeWithException(ApiFailure("Could not reach the provider. Check your connection and API settings."))
            }
            override fun onResponse(call: Call, response: Response) {
                try {
                    val result = response.use {
                        if (!it.isSuccessful) throw ApiFailure(when (it.code) {
                            401, 403 -> "API authorization failed. Check your key and model access."
                            404 -> "API endpoint or model was not found. Check API settings."
                            413 -> "Recording is too large for the provider. Try a shorter dictation."
                            429 -> "Provider limit reached. Check quota or retry later."
                            in 300..399 -> "The provider redirected the request. Save its direct HTTPS API URL."
                            else -> "Provider request failed (HTTP ${it.code}). Try again or check API settings."
                        })
                        val body = it.body ?: throw ApiFailure("The provider returned an empty response.")
                        body.byteStream().use { stream ->
                            val bytes = stream.readNBytes(MAX_RESPONSE_BYTES + 1)
                            if (bytes.size > MAX_RESPONSE_BYTES) throw ApiFailure("The provider response was too large.")
                            bytes.toString(Charsets.UTF_8)
                        }
                    }
                    if (continuation.isActive) continuation.resume(result)
                } catch (failure: Exception) {
                    if (continuation.isActive) continuation.resumeWithException(
                        if (failure is ApiFailure) failure else ApiFailure("Could not read the provider response. Try again."))
                }
            }
        })
    }

    private companion object { const val MAX_RESPONSE_BYTES = 2 * 1024 * 1024 }
}

internal fun canonicalEndpoint(settings: Settings, allowLocalTest: Boolean = false): String {
    val base = if(settings.provider == "anthropic") "https://api.anthropic.com/v1" else settings.baseUrl.trim().trimEnd('/')
    val u = base.toHttpUrlOrNull() ?: throw ApiFailure("Enter a valid HTTPS text provider URL.")
    require((u.isHttps || (allowLocalTest && u.host in setOf("localhost","127.0.0.1","::1"))) && u.username.isEmpty() && u.password.isEmpty() && u.query == null && u.fragment == null) { "Use HTTPS without credentials, query or fragment." }
    require(settings.provider in setOf("anthropic", "openai-compatible")) { "This text provider is unavailable on Android." }
    return u.toString().trimEnd('/')
}
internal fun credentialScope(settings: Settings) = settings.provider + "|" + canonicalEndpoint(settings)

internal fun validateProviderKey(key: String) {
    if (key.length > 8192 || key.any { it.code !in 33..126 }) {
        throw ApiFailure("The API key contains unsupported characters. Re-enter it using printable ASCII without spaces.")
    }
}
