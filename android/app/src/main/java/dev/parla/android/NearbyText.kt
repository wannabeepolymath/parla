package dev.parla.android

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import java.security.MessageDigest
import java.text.Normalizer
import java.util.Locale
import org.json.JSONArray

/** Ephemeral request material: a bounded prefix before the cursor and the live grant check. Never saved or logged. */
class NearbyContext internal constructor(val prefix: String, val authorized: () -> Boolean)

/**
 * Mac SurroundingTextPolicy: off by default, reviewed per app, bound to the exact provider, model, profile and
 * cleanup settings that were shown. Any change to those drops the grant ([prune]); it never comes back by itself.
 */
internal object NearbyText {
    const val REQUESTED_UNITS = 512
    const val RETAINED_UNITS = 256
    const val MAX_REQUEST_BYTES = 16 * 1024
    // Mac NativeSurroundingText.allowedApp, plus Android browsers: one browser profile would cover every website.
    private val forbidden = listOf("1password", "onepassword", "agilebits", "bitwarden", "lastpass", "dashlane", "keepass", "enpass", "strongbox", "keychain",
        "password", "protonpass", "nordpass", "msecure", "keeweb", "buttercup", "lockwise", "passbolt", "padloc", "roboform", "safeincloud", "keeper", "secrets",
        "terminal", "iterm", "ghostty", "wezterm", "alacritty", "kitty", "hyper", "warp", "remote", "teamviewer", "anydesk", "termux", "browser")
    private val browsers = setOf("com.android.chrome", "com.chrome.beta", "com.chrome.dev", "com.chrome.canary", "org.chromium.chrome", "org.mozilla.firefox",
        "org.mozilla.firefox_beta", "org.mozilla.fenix", "org.mozilla.focus", "com.microsoft.emmx", "com.opera.mini.native", "com.opera.gx", "com.sec.android.app.sbrowser",
        "com.duckduckgo.mobile.android", "com.vivaldi.browser", "com.kiwibrowser.browser", "com.brave.browser")
    // A failed save must not leave a declined grant usable in this process.
    @Volatile private var revoked = setOf<String>()

    fun allowedApp(pkg: String): Boolean {
        val lower = pkg.lowercase(Locale.ROOT)
        val letters = lower.filter { it.isLetterOrDigit() }
        return pkg.isNotEmpty() && lower !in browsers && forbidden.none { letters.contains(it) } &&
            TextRules.category(pkg) != AppCategory.terminal && TextRules.category(pkg) != AppCategory.code
    }

    /** Reviewable identity, or null when this app can't use nearby text with the current settings. */
    fun signature(data: LocalData, pkg: String): String? {
        val s = data.settings
        if (!allowedApp(pkg) || s.outputMode != "cleanup" || s.backups.isNotEmpty()) return null
        val profile = data.profiles.firstOrNull { it.enabled && it.target == pkg } ?: return null
        val effective = data.forApp(pkg).settings
        if (!effective.cleanupEnabled) return null
        val endpoint = runCatching { effective.endpoint() }.getOrNull() ?: return null
        if (endpoint.model.isBlank()) return null // Discovery is never an exact reviewed model.
        val value = JSONArray().put(1).put(pkg).put(endpoint.provider).put(endpoint.baseUrl).put(endpoint.model)
            .put(JSONArray(listOf(profile.id, profile.name, profile.cleanup, profile.style, profile.language, profile.localModel, profile.cleanupModel)))
            .put(JSONArray(profile.vocabulary)).put(JSONArray(data.dictionary))
            .put(JSONArray(data.snippets.map { JSONArray(listOf(it.trigger, it.expansion)) }))
            .put(JSONArray(data.replacements.map { JSONArray(listOf(it.source, it.replacement)) }))
            .put(s.style).put(s.backupReview)
        return MessageDigest.getInstance("SHA-256").digest(value.toString().toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }
    }

    fun granted(data: LocalData, pkg: String): Boolean = pkg !in revoked && signature(data, pkg).let { it != null && data.settings.nearbyText[pkg] == it }

    /** Compare-and-set against the exact settings the user reviewed. */
    fun grant(data: LocalData, pkg: String, reviewed: String): LocalData {
        if (signature(data, pkg) != reviewed) return data
        return data.copy(settings = data.settings.copy(nearbyText = data.settings.nearbyText + (pkg to reviewed)))
    }

    fun revoke(store: Store, pkg: String): Boolean {
        revoked = revoked + pkg
        return store.update { it.copy(settings = it.settings.copy(nearbyText = it.settings.nearbyText - pkg)) }
    }

    fun confirm(store: Store, pkg: String, reviewed: String): Boolean {
        if (!store.update { grant(it, pkg, reviewed) }) return false
        if (store.data.value.settings.nearbyText[pkg] != reviewed) return false
        revoked = revoked - pkg
        return true
    }

    /** Applied to every saved change: a stale grant is removed, so changing settings back never re-enables it. */
    fun prune(data: LocalData): LocalData {
        val kept = data.settings.nearbyText.filter { (pkg, reviewed) -> signature(data, pkg) == reviewed }
        return if (kept.size == data.settings.nearbyText.size) data else data.copy(settings = data.settings.copy(nearbyText = kept))
    }

    /**
     * Text before a collapsed cursor only: at most 256 UTF-16 units of whole characters.
     * Sensitive, URL and email fields and any selection give nothing.
     */
    fun prefix(editor: EditorSnapshot): String {
        val variation = editor.inputType and 0x0ff0
        if (!InsertionPolicy.safe(editor) || editor.selectionStart != editor.selectionEnd || variation in setOf(0x10, 0x20, 0xd0)) return ""
        val caret = editor.selectionStart
        val window = Regex("\\X").findAll(editor.text.substring((caret - REQUESTED_UNITS).coerceAtLeast(0), caret)).map { it.value }.toList()
        // ponytail: no separate byte count. 256 UTF-16 units encode to at most 768 UTF-8 bytes, inside Mac's 1,024.
        var start = window.size; var units = 0
        while (start > 0 && units + window[start - 1].length <= RETAINED_UNITS) { units += window[start - 1].length; start-- }
        return window.subList(start, window.size).joinToString("")
    }

    private val fillers = setOf("uh", "um", "er", "ah", "hmm", "mm")
    private fun spans(text: String): Set<List<String>> {
        val folded = Normalizer.normalize(text, Normalizer.Form.NFKC).filter { Character.getType(it) != Character.FORMAT.toInt() }
        val words = folded.lowercase(Locale.ROOT).split(Regex("[^\\p{L}\\p{M}\\p{N}]+")).filter { it.isNotEmpty() && it !in fillers }
        return if (words.size < 4) emptySet() else (0..words.size - 4).map { words.subList(it, it + 4) }.toSet()
    }

    /** Mac containsUnsupportedEcho: four consecutive nearby words that weren't dictated appear in the reply. */
    fun echoes(prefix: String, output: String, transcript: String): Boolean {
        val unsupported = spans(prefix) - spans(transcript)
        return unsupported.isNotEmpty() && spans(output).any { it in unsupported }
    }

    fun disclosure(data: LocalData, pkg: String): String {
        val e = data.forApp(pkg).settings.endpoint()
        return "With each dictation in $pkg, parla will send about 256 characters of text before the cursor — text you didn’t dictate — " +
            "to ${e.label} (${e.baseUrl}, model ${e.model}). Text after the cursor is never sent, and parla doesn’t save nearby text. " +
            "Password, private, email and web-address fields are skipped. Uses the API key saved in parla. Each request may be billed by ${e.label}. " +
            "Changing this profile, your cleanup settings or your dictionary turns this off until you turn it on again."
    }
}

@Composable internal fun NearbyTextSection(data: LocalData, store: Store, message: (String) -> Unit) {
    var review by remember { mutableStateOf<Pair<String, String>?>(null) }
    HorizontalDivider()
    Text("Nearby text", style = MaterialTheme.typography.titleMedium)
    Text("Off unless you turn it on for an app. About 256 characters before the cursor are then sent to your AI provider with each dictation, to help get names and sentences right. It’s never saved. Needs AI cleanup on, Clean up speech output, a model ID and no backup providers. Browsers, terminals and password managers can’t use it.")
    data.profiles.filter { it.enabled }.distinctBy { it.target }.forEach { p ->
        val on = NearbyText.granted(data, p.target)
        val signature = NearbyText.signature(data, p.target)
        Text("${p.name} · ${if (on) "On" else if (signature != null) "Off" else "Not available"}")
        Row {
            TextButton(onClick = { review = p.target to signature!! }, enabled = !on && signature != null) { Text("Turn on…") }
            TextButton(onClick = { message(if (NearbyText.revoke(store, p.target)) "Nearby text is off." else "Paused, but couldn’t save. Check Data recovery.") }, enabled = on) { Text("Turn off") }
        }
    }
    review?.let { (pkg, signature) ->
        val text = runCatching { NearbyText.disclosure(data, pkg) }.getOrNull()
        AlertDialog(onDismissRequest = { review = null }, title = { Text("Send nearby text for this app?") },
            text = { Text(text ?: "This app can’t use nearby text right now.", Modifier.verticalScroll(rememberScrollState())) },
            confirmButton = { TextButton(onClick = {
                review = null
                message(if (NearbyText.confirm(store, pkg, signature)) "Nearby text is on for $pkg." else "Settings changed. Review again.")
            }, enabled = text != null) { Text("Send nearby text for this app") } },
            dismissButton = { TextButton(onClick = { review = null }) { Text("Cancel") } })
    }
}
