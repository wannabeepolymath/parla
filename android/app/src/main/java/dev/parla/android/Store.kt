package dev.parla.android

import android.content.Context
import java.io.File
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/** Successful durable write precedes publication. A failed load gates all writes and provider access. */
class Store private constructor(context: Context) {
    private val stateFile = DurableFile(File(context.filesDir, "parla-data.json"))
    private val keys = ProviderKeys(File(context.noBackupFilesDir, "provider-keys"), DurableFile(File(context.noBackupFilesDir, "provider-key.enc")), KeystoreSealer)
    private val local = LocalState(FileStateStorage(stateFile))
    val persistenceError = local.error
    val data = local.data
    fun hasKey(scope: String): Boolean = runCatching { keys.has(scope) }.getOrDefault(false)
    val ready: Boolean get() = !local.blocked
    @Volatile internal var accessibilityConsentDeclined = false
        private set
    val accessibilityConsentGranted: Boolean
        get() = ready && !accessibilityConsentDeclined && data.value.settings.accessibilityConsentCurrent()
    fun setAccessibilityConsent(granted: Boolean): Boolean {
        // A failed disk write must not leave declined access usable in this process.
        if (!granted) accessibilityConsentDeclined = true
        val saved = update { it.copy(settings = it.settings.withAccessibilityConsent(granted)) }
        if (granted && saved) accessibilityConsentDeclined = false
        return saved
    }
    fun update(transform: (LocalData) -> LocalData) = local.update { NearbyText.prune(transform(it)) }
    fun reload() = local.reload()
    fun recoverySource() = local.original()
    fun repair(json: String) = local.repair(json)
    /** Saves this provider's configuration and, if entered, its own key. Other providers' keys are untouched. */
    @Synchronized fun saveConnection(settings: Settings, enteredKey: String) {
        check(ready) { "Reload or repair data before changing your API connection." }
        val scope = settings.endpoint().scope
        val value = enteredKey.trim()
        validateProviderKey(value)
        check(update { it.copy(settings = settings) }) { "API settings were not saved." }
        // A key saved before keys were bound to an address is adopted only by this explicit save.
        if(value.isNotEmpty()) keys.save(scope, value) else keys.adoptLegacy(scope)
    }
    @Synchronized fun saveKey(scope: String, value: String) {
        check(ready) { "Reload or repair local data first." }
        keys.save(scope, value.trim())
    }
    /** Revocation is always available, including while unrelated settings require repair. */
    @Synchronized fun removeKey(scope: String) = keys.remove(scope)
    /** Only the key bound to [scope], or "" when none is saved. */
    @Synchronized fun readKey(scope: String): String {
        check(ready) { "AI cleanup is paused. Reload or repair saved data." }
        return keys.read(scope).orEmpty()
    }

    companion object {
        @Volatile private var instance: Store? = null
        fun get(context: Context): Store = instance ?: synchronized(this) { instance ?: Store(context.applicationContext).also { instance = it } }
    }
}

internal object LocalDataCodec {
    fun encode(data: LocalData): String {
        val s = data.settings
        val settings = JSONObject()
            .put("onboarded", s.onboarded)
            .put("accessibilityConsentGranted", s.accessibilityConsentGranted)
            .put("accessibilityConsentVersion", s.accessibilityConsentVersion)
            .put("provider", s.provider)
            .put("providers", JSONObject(s.providers.mapValues { (_, c) -> JSONObject().put("baseUrl", c.baseUrl).put("model", c.model) }))
            .put("backups", JSONArray(s.backups.map { JSONObject().put("provider", it.provider).put("baseUrl", it.baseUrl).put("model", it.model).put("keyless", it.keyless) }))
            .put("backupReview", s.backupReview)
            .put("localModel", s.localModel)
            .put("language", s.language)
            .put("style", s.style)
            .put("cleanupEnabled", s.cleanupEnabled)
            .put("outputMode", s.outputMode)
            .put("selectedPresetID", s.selectedPresetID)
            .put("noHistory", s.noHistory)
            .put("recoveryAudioEnabled", s.recoveryAudioEnabled)
            .put("recoveryAudioDays", s.recoveryAudioDays)
            .put("historyLimit", s.historyLimit)
            .put("bubbleSize", s.bubbleSize.toDouble())
            .put("bubbleOpacity", s.bubbleOpacity.toDouble())
            .put("bubbleX", s.bubbleX)
            .put("bubbleY", s.bubbleY)
            .put("bubbleDocked", s.bubbleDocked)
            .put("nearbyText", JSONObject(s.nearbyText))
        return JSONObject().put("version", 5).put("settings", settings)
            .put("dictionary", JSONArray(data.dictionary))
            .put("snippets", JSONArray(data.snippets.map { JSONObject().put("id",it.id).put("trigger",it.trigger).put("expansion",it.expansion) }))
            .put("history", JSONArray(data.history.map { JSONObject().put("id",it.id).put("createdAt",it.createdAt).put("raw",it.raw).put("text",it.text).put("note",it.note).put("durationMs",it.durationMs).put("revision",it.revision).put("app",it.app).put("model",it.model).put("latencyMs",it.latencyMs) }))
            .put("replacements", JSONArray(data.replacements.map { JSONObject().put("source",it.source).put("replacement",it.replacement) }))
            .put("presets", JSONArray(data.presets.map { JSONObject().put("id",it.id).put("name",it.name).put("kind",it.kind).put("instruction",it.instruction).put("targetLanguage",it.targetLanguage) }))
            .put("profiles", JSONArray(data.profiles.map { JSONObject().put("id",it.id).put("name",it.name).put("target",it.target).put("enabled",it.enabled).put("cleanup",it.cleanup).put("style",it.style).put("language",it.language).put("localModel",it.localModel).put("cleanupModel",it.cleanupModel).put("vocabulary",JSONArray(it.vocabulary)) }))
            .toString()
    }
    fun decode(json: String): LocalData {
        val parser = org.json.JSONTokener(json)
        val root = parser.nextValue() as? JSONObject ?: error("Expected local data object")
        require(parser.nextClean() == '\u0000') { "Unexpected trailing local data" }
        require(root.get("version") is Int)
        val version = root.getInt("version"); require(version in 1..5) { "Unsupported local schema" }
        val s = root.getJSONObject("settings"); val d = Settings()
        // Reject malformed known fields instead of opt* silently reusing defaults.
        require(!s.has("onboarded") || s.get("onboarded") is Boolean)
        require(!s.has("accessibilityConsentGranted") || s.get("accessibilityConsentGranted") is Boolean)
        // Missing means the unversioned 1.3.1 disclosure. A newer version still loads; it just isn't current consent.
        require(!s.has("accessibilityConsentVersion") || (s.get("accessibilityConsentVersion") as? Int ?: 0) >= 1)
        require(!s.has("provider") || s.get("provider") is String)
        require(!s.has("baseUrl") || s.get("baseUrl") is String)
        require(!s.has("cleanupModel") || s.get("cleanupModel") is String)
        require(!s.has("localModel") || s.get("localModel") is String)
        require(!s.has("language") || s.get("language") is String)
        require(!s.has("style") || s.get("style") is String)
        require(!s.has("cleanupEnabled") || s.get("cleanupEnabled") is Boolean)
        require(!s.has("outputMode") || s.get("outputMode") is String)
        require(!s.has("selectedPresetID") || s.get("selectedPresetID") is String)
        require(!s.has("noHistory") || s.get("noHistory") is Boolean)
        require(!s.has("recoveryAudioEnabled") || s.get("recoveryAudioEnabled") is Boolean)
        require(!s.has("recoveryAudioDays") || s.get("recoveryAudioDays") is Int)
        require(!s.has("historyLimit") || s.get("historyLimit") is Number)
        require(!s.has("bubbleSize") || s.get("bubbleSize") is Number)
        require(!s.has("bubbleOpacity") || s.get("bubbleOpacity") is Number)
        require(!s.has("bubbleX") || s.get("bubbleX") is Number)
        require(!s.has("bubbleY") || s.get("bubbleY") is Number)
        require(!s.has("bubbleDocked") || s.get("bubbleDocked") is Boolean)
        require(!s.has("backupReview") || s.get("backupReview") is String)
        val nearby = if(s.has("nearbyText")) s.getJSONObject("nearbyText").let { o -> o.keys().asSequence().associateWith { o.get(it) as? String ?: error("Bad nearby text grant") } } else emptyMap()
        require(nearby.all { (pkg, sig) -> pkg.length <= 255 && Regex("[0-9a-f]{64}").matches(sig) })
        // Schema 5 keeps one configuration per provider. Older schemas had one wire format + base + model.
        val savedProvider = if(version == 1) "openai-compatible" else if(s.has("provider")) s.getString("provider") else d.provider
        val legacyBase = if(s.has("baseUrl")) s.getString("baseUrl") else if(version == 1) "https://api.openai.com/v1" else "https://api.anthropic.com/v1"
        val provider = if(version >= 5) savedProvider else ProviderCatalog.forLegacy(savedProvider, legacyBase)
        val providers = if(version >= 5) (if(s.has("providers")) s.getJSONObject("providers") else JSONObject()).let { o ->
            o.keys().asSequence().associateWith { id -> o.getJSONObject(id).let { ProviderConfig(it.getString("baseUrl"), it.getString("model")) } }
        } else if(ProviderCatalog.find(provider) == null) emptyMap() else mapOf(provider to ProviderConfig(
            if(provider == "custom") canonicalBase(legacyBase) else ProviderCatalog.find(provider)!!.baseUrl,
            (if(s.has("cleanupModel")) s.getString("cleanupModel") else if(version == 1) "gpt-4.1-mini" else "claude-haiku-4-5").trim()))
        val backups = objects(s,"backups").map { CleanupBackup(it.getString("provider"), it.getString("baseUrl"), it.getString("model"), it.getBoolean("keyless")) }
        require(providers.all { (id, c) -> ProviderCatalog.find(id) != null && c.baseUrl.length <= 4096 && c.model.length <= 200 })
        require(backups.size <= CleanupFailover.MAX_BACKUPS && backups.all { ProviderCatalog.find(it.provider) != null && it.baseUrl.length <= 4096 && it.model.length <= 200 })
        val settings = Settings(
            onboarded = if(s.has("onboarded")) s.getBoolean("onboarded") else d.onboarded,
            // Earlier schemas never recorded this disclosure's explicit consent.
            accessibilityConsentGranted = version >= 4 && s.getBoolean("accessibilityConsentGranted"),
            accessibilityConsentVersion = if(s.has("accessibilityConsentVersion")) s.getInt("accessibilityConsentVersion") else 1,
            provider = provider, providers = providers, backups = backups,
            backupReview = if(s.has("backupReview")) s.getString("backupReview") else d.backupReview,
            localModel = if(s.has("localModel")) s.getString("localModel") else d.localModel,
            language = if(s.has("language")) s.getString("language") else d.language,
            style = if(version == 1) "standard" else if(s.has("style")) s.getString("style") else d.style,
            cleanupEnabled = if(s.has("cleanupEnabled")) s.getBoolean("cleanupEnabled") else d.cleanupEnabled,
            outputMode = if(s.has("outputMode")) s.getString("outputMode") else d.outputMode,
            selectedPresetID = if(s.has("selectedPresetID")) s.getString("selectedPresetID") else d.selectedPresetID,
            noHistory = if(s.has("noHistory")) s.getBoolean("noHistory") else d.noHistory,
            // Existing Android users never consented to retained audio. Only schema3 persists opt-in.
            recoveryAudioEnabled = version >= 3 && s.getBoolean("recoveryAudioEnabled"),
            recoveryAudioDays = if(version >= 3) s.getInt("recoveryAudioDays") else 7,
            historyLimit = if(s.has("historyLimit")) s.getInt("historyLimit") else if(version == 1) maxOf(50,root.optJSONArray("history")?.length() ?: 0).coerceAtMost(1000) else d.historyLimit,
            bubbleSize = if(s.has("bubbleSize")) s.getDouble("bubbleSize").toFloat() else d.bubbleSize,
            bubbleOpacity = if(s.has("bubbleOpacity")) s.getDouble("bubbleOpacity").toFloat() else d.bubbleOpacity,
            bubbleX = if(s.has("bubbleX")) s.getInt("bubbleX") else d.bubbleX,
            bubbleY = if(s.has("bubbleY")) s.getInt("bubbleY") else d.bubbleY,
            bubbleDocked = if(s.has("bubbleDocked")) s.getBoolean("bubbleDocked") else d.bubbleDocked,
            nearbyText = nearby,
        )
        require(settings.language == "auto" || settings.language in SpeechLanguages.codes)
        require(settings.recoveryAudioDays in 1..30)
        require(settings.historyLimit in 1..1000 && settings.style in setOf("standard","conversational","formal") && settings.outputMode in setOf("cleanup","raw","selectedPreset"))
        require(ProviderCatalog.find(settings.provider) != null || settings.provider == "apple-intelligence")
        require(settings.bubbleSize.isFinite() && settings.bubbleSize in .7f..1.5f && settings.bubbleOpacity.isFinite() && settings.bubbleOpacity in .2f..1f)
        val words = strings(root,"dictionary"); require(words.size <= 1000)
        val snippets = objects(root,"snippets").map { Snippet(it.getString("id"),it.getString("trigger"),it.getString("expansion")) }
        val history = objects(root,"history").map { HistoryEntry(it.getString("id"),it.getLong("createdAt"),it.getString("raw"),it.getString("text"),it.optString("note"),it.optLong("durationMs"),it.optLong("revision"),it.optString("app"),it.optString("model"),it.optLong("latencyMs")) }
        val rules = objects(root,"replacements").map { LiteralReplacement(it.getString("source"),it.getString("replacement")) }
        val presets = objects(root,"presets").map { TransformPreset(it.getString("id"),it.getString("name"),it.getString("kind"),it.getString("instruction"),it.getString("targetLanguage")).also { p -> p.validate() } }
        val profiles = objects(root,"profiles").map { AppProfile(it.getString("id"),it.getString("name"),it.getString("target"),it.getBoolean("enabled"),it.getString("cleanup"),it.getString("style"),it.getString("language"),it.getString("localModel"),it.getString("cleanupModel"),strings(it,"vocabulary")).also { p -> p.validate() } }
        require(history.map { it.id }.distinct().size == history.size && presets.map { it.id }.distinct().size == presets.size && profiles.map { it.id }.distinct().size == profiles.size)
        // Legacy text remains even if history was disabled. Disable is non-destructive.
        return LocalData(settings,words,snippets,history,rules,presets,profiles)
    }
    private fun array(root: JSONObject, key: String): JSONArray = if(root.has(key)) root.getJSONArray(key) else JSONArray()
    private fun strings(root: JSONObject, key: String): List<String> = array(root,key).let { a -> (0 until a.length()).map { require(a.get(it) is String); a.getString(it) } }
    private fun objects(root: JSONObject, key: String): List<JSONObject> = array(root,key).let { a -> (0 until a.length()).map { a.getJSONObject(it) } }
}
