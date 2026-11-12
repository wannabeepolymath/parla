package dev.parla.android

import java.util.UUID

data class Settings(
    val onboarded: Boolean = false,
    val provider: String = "anthropic",
    val baseUrl: String = "https://api.anthropic.com/v1",
    val cleanupModel: String = "claude-haiku-4-5",
    val localModel: String = "base.en",
    val language: String = "auto",
    val style: String = "standard",
    val cleanupEnabled: Boolean = true,
    val outputMode: String = "cleanup",
    val selectedPresetID: String = "",
    val noHistory: Boolean = false,
    val recoveryAudioEnabled: Boolean = true,
    val recoveryAudioDays: Int = 7,
    val historyLimit: Int = 50,
    val bubbleSize: Float = .85f,
    val bubbleOpacity: Float = .8f,
    val bubbleX: Int = 16,
    val bubbleY: Int = 280,
    val bubbleDocked: Boolean = true,
)
data class Snippet(val id: String = UUID.randomUUID().toString(), val trigger: String, val expansion: String)
data class LiteralReplacement(val source: String, val replacement: String)
data class TransformPreset(val id: String = UUID.randomUUID().toString(), val name: String, val kind: String = "rewrite", val instruction: String = "", val targetLanguage: String = "") {
    fun validate() {
        require(name.trim().toByteArray().size in 1..120) { "Enter a short preset name (up to 120 English characters; fewer for some languages)." }
        require(kind in setOf("rewrite", "translation"))
        require((if (kind == "rewrite") instruction.trim() else targetLanguage.trim()).toByteArray().size in 1..(if (kind == "rewrite") 8192 else 120)) { "Enter rewrite instructions or a language to translate into. Shorten the text if it is too long." }
    }
    val intent get() = if (kind == "translation") "Translate the source text into this explicitly chosen target language: ${targetLanguage.trim()}. Preserve its meaning." else instruction.trim()
}
data class AppProfile(val id: String = UUID.randomUUID().toString(), val name: String, val target: String, val enabled: Boolean = true, val cleanup: String = "inherit", val style: String = "", val language: String = "", val localModel: String = "", val cleanupModel: String = "", val vocabulary: List<String> = emptyList()) {
    fun validate() {
        require(name.isNotBlank() && Regex("[A-Za-z0-9_]+(?:\\.[A-Za-z0-9_]+)+").matches(target)) { "Enter a name and an app package name, such as com.whatsapp." }
        require(cleanup in setOf("inherit", "on", "off") && style in setOf("", "standard", "conversational", "formal"))
        require(vocabulary.all { it.toByteArray().size <= 256 }) { "A priority word is too long. Shorten it and try again." }
        require(language.isEmpty() || language == "auto" || language in SpeechLanguages.codes) { "Enter a supported language code, such as en, or auto to detect it." }
        require(localModel.isEmpty() || ModelCatalog.all.any { it.id == localModel })
    }
}
data class HistoryEntry(val id: String = UUID.randomUUID().toString(), val createdAt: Long = System.currentTimeMillis(), val raw: String, val text: String, val note: String = "", val durationMs: Long = 0, val revision: Long = 0)
data class LocalData(val settings: Settings = Settings(), val dictionary: List<String> = emptyList(), val snippets: List<Snippet> = emptyList(), val history: List<HistoryEntry> = emptyList(), val replacements: List<LiteralReplacement> = emptyList(), val presets: List<TransformPreset> = emptyList(), val profiles: List<AppProfile> = emptyList()) {
    fun forApp(packageName: String?): LocalData {
        val p = profiles.firstOrNull { it.enabled && it.target == packageName } ?: return this
        return copy(settings = settings.copy(cleanupEnabled = when(p.cleanup) { "on" -> true; "off" -> false; else -> settings.cleanupEnabled }, style = p.style.ifEmpty { settings.style }, language = p.language.ifEmpty { settings.language }, localModel = p.localModel.ifEmpty { settings.localModel }, cleanupModel = p.cleanupModel.ifEmpty { settings.cleanupModel }), dictionary = p.vocabulary + dictionary)
    }
}
data class CleanupResult(val text: String, val warning: String? = null)
enum class Phase { IDLE, RECORDING, PROCESSING, ERROR }
data class DictationStatus(val phase: Phase = Phase.IDLE, val message: String = "Ready when you are", val level: Float = 0f)
