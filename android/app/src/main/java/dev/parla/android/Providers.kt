package dev.parla.android

import java.net.InetAddress
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/** Saved per provider; switching providers never rewrites another provider's values. */
data class ProviderConfig(val baseUrl: String, val model: String)

/**
 * Named presets of the two Mac wire formats. Anthropic has its own Messages API; every other
 * preset is the Mac's generic OpenAI-compatible client with a fixed address.
 */
internal data class ProviderPreset(val id: String, val label: String, val baseUrl: String, val model: String)

internal object ProviderCatalog {
    val all = listOf(
        ProviderPreset("anthropic", "Anthropic", "https://api.anthropic.com/v1", "claude-haiku-4-5"),
        ProviderPreset("openai", "OpenAI", "https://api.openai.com/v1", "gpt-4.1-mini"),
        ProviderPreset("groq", "Groq", "https://api.groq.com/openai/v1", "openai/gpt-oss-120b"),
        ProviderPreset("gemini", "Gemini", "https://generativelanguage.googleapis.com/v1beta/openai", "gemini-2.5-flash"),
        // The Mac has no OpenRouter default; the user picks a model.
        ProviderPreset("openrouter", "OpenRouter", "https://openrouter.ai/api/v1", ""),
        ProviderPreset("custom", "Custom (OpenAI-compatible)", "", ""),
    )
    fun find(id: String) = all.firstOrNull { it.id == id }
    fun default(id: String) = ProviderConfig(find(id)?.baseUrl.orEmpty(), find(id)?.model.orEmpty())
    /** Schemas before 5 stored the wire format. A compatible base matching a named preset becomes that preset. */
    fun forLegacy(provider: String, base: String): String {
        if (provider != "openai-compatible") return provider
        val canonical = runCatching { canonicalBase(base) }.getOrNull()
        return all.firstOrNull { it.id != "anthropic" && it.id != "custom" && it.baseUrl == canonical }?.id ?: "custom"
    }
}

/** A resolved destination. The credential scope keeps the pre-1.3.2 format so saved keys stay reachable. */
internal data class Endpoint(val provider: String, val baseUrl: String, val model: String) {
    val anthropic get() = provider == "anthropic"
    val custom get() = provider == "custom"
    val scope get() = (if (anthropic) "anthropic" else "openai-compatible") + "|" + baseUrl
    val cleartext get() = baseUrl.startsWith("http://")
    val local get() = cleartext || isLocalHost(baseUrl.toHttpUrlOrNull()?.host.orEmpty())
    val label get() = ProviderCatalog.find(provider)?.label ?: provider
}

internal fun endpointFor(provider: String, config: ProviderConfig): Endpoint {
    val preset = ProviderCatalog.find(provider) ?: throw ApiFailure(
        if (provider == "apple-intelligence") "Apple Intelligence is unavailable on Android. Choose a provider in API connection."
        else "Choose a text provider in API connection.", ApiFailure.Kind.setup)
    return Endpoint(preset.id, if (preset.id == "custom") canonicalBase(config.baseUrl) else preset.baseUrl, config.model.trim())
}
internal val Settings.active get() = providers[provider] ?: ProviderCatalog.default(provider)
internal fun Settings.endpoint() = endpointFor(provider, active)
internal fun CleanupBackup.endpoint() = endpointFor(provider, ProviderConfig(baseUrl, model))

/**
 * Mac CredentialScope.compatible: http or https, no credentials, query or fragment.
 * Android adds one rule: http only reaches private-network hosts (checked again after DNS in ApiClient).
 */
internal fun canonicalBase(raw: String): String {
    val u = raw.trim().trimEnd('/').toHttpUrlOrNull()
    if (u == null || raw.length > 4096 || u.username.isNotEmpty() || u.password.isNotEmpty() || u.query != null || u.fragment != null)
        throw ApiFailure("Enter a valid API address, without a password, query or fragment.", ApiFailure.Kind.setup)
    if (!u.isHttps && isIpLiteral(u.host) && !isPrivateAddress(InetAddress.getByName(u.host)))
        throw ApiFailure(PUBLIC_CLEARTEXT, ApiFailure.Kind.setup)
    return u.toString().trimEnd('/')
}
internal const val PUBLIC_CLEARTEXT = "http:// works only for servers on your local network. Use https:// for servers on the internet."

internal fun isIpLiteral(host: String) = host.contains(':') || Regex("""\d{1,3}(\.\d{1,3}){3}""").matches(host)
internal fun isLocalHost(host: String) = host == "localhost" || host.endsWith(".local") ||
    (isIpLiteral(host) && runCatching { isPrivateAddress(InetAddress.getByName(host)) }.getOrDefault(false))
/** Loopback, RFC 1918, link-local, IPv6 unique-local and CGNAT (Tailscale-style) addresses. */
internal fun isPrivateAddress(address: InetAddress): Boolean {
    val b = address.address
    return address.isLoopbackAddress || address.isSiteLocalAddress || address.isLinkLocalAddress ||
        (b.size == 16 && (b[0].toInt() and 0xfe) == 0xfc) ||
        (b.size == 4 && (b[0].toInt() and 0xff) == 100 && (b[1].toInt() and 0xc0) == 64)
}

/** The selected provider and its saved configuration both come from one captured endpoint. */
internal fun Settings.withConnection(e: Endpoint) = copy(provider = e.provider, providers = providers + (e.provider to ProviderConfig(e.baseUrl, e.model)))
/** Unsaved key drafts belong to a destination, not a row: changing or reordering a row never moves a draft. */
internal fun Map<String, String>.draftFor(e: Endpoint?) = e?.let { this[it.scope] }.orEmpty()
