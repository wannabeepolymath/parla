package dev.parla.android

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import org.json.JSONArray
import org.json.JSONObject

/** Successful durable write precedes publication. A failed load gates all writes and provider access. */
class Store private constructor(context: Context) {
    private val stateFile = DurableFile(File(context.filesDir, "parla-data.json"))
    private val keyFile = DurableFile(File(context.noBackupFilesDir, "provider-key.enc"))
    private val local = LocalState(FileStateStorage(stateFile))
    val persistenceError = local.error
    val data = local.data
    val hasKey: Boolean get() = keyFile.baseFile.exists()
    val ready: Boolean get() = !local.blocked
    fun update(transform: (LocalData) -> LocalData) = local.update(transform)
    fun reload() = local.reload()
    fun recoverySource() = local.original()
    fun repair(json: String) = local.repair(json)
    @Synchronized fun saveConnection(settings: Settings, enteredKey: String) {
        check(ready) { "Reload or repair local data before changing provider settings." }
        val scope = credentialScope(settings)
        // Blank explicitly rebinds the existing key only from this user-invoked save action.
        val value = if(enteredKey.isBlank() && hasKey) decryptKey().second else enteredKey.trim()
        validateProviderKey(value)
        check(update { it.copy(settings = settings) }) { "Provider settings were not saved." }
        if(value.isNotEmpty()) saveBoundKey(value, scope)
    }
    @Synchronized fun saveKey(value: String) {
        // Revocation is always available, including while unrelated settings require repair.
        if(value.isBlank()) { keyFile.delete(); check(!hasKey) { "Saved key could not be removed. Check device storage and try again." }; return }
        check(ready) { "Reload or repair local data first." }
        saveBoundKey(value, credentialScope(data.value.settings))
    }
    private fun saveBoundKey(value: String, scope: String) {
        validateProviderKey(value)
        try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, secretKey())
            val payload = JSONObject().put("scope",scope).put("key",value).toString().toByteArray()
            val encrypted = cipher.doFinal(payload)
            keyFile.write(byteArrayOf(2, cipher.iv.size.toByte()) + cipher.iv + encrypted)
        } catch(_: Exception) { throw IllegalStateException("Key was not saved securely. Re-enter it and save again.") }
    }
    @Synchronized fun readKey(settings: Settings = data.value.settings): String {
        check(ready) { "Provider work blocked: reload or repair unreadable local data." }
        if(!hasKey) return ""
        val (scope,key) = decryptKey()
        check(scope == credentialScope(settings)) { "Saved key is not bound to this endpoint. Review and Save API settings explicitly." }
        return key
    }
    private fun decryptKey(): Pair<String,String> {
        try {
            val bytes = keyFile.read(32769) ?: error("Saved key missing")
            require(bytes.size in 30..32768 && bytes[0].toInt() in 1..2)
            val ivSize = bytes[1].toInt(); require(ivSize == 12 && bytes.size > 2+ivSize+16)
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128,bytes.copyOfRange(2,2+ivSize)))
            val plain = cipher.doFinal(bytes.copyOfRange(2+ivSize,bytes.size)).toString(Charsets.UTF_8)
            if(bytes[0].toInt() == 1) return "legacy-unbound" to plain
            val json = JSONObject(plain); return json.getString("scope") to json.getString("key")
        } catch(_: Exception) { throw IllegalStateException("Saved key cannot be unlocked. Remove it and save a key again; local speech still works.") }
    }
    private fun secretKey(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
            init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM).setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256).build())
        }.generateKey()
    }

    companion object {
        private const val KEY_ALIAS = "parla-provider-key-v1"
        @Volatile private var instance: Store? = null
        fun get(context: Context): Store = instance ?: synchronized(this) { instance ?: Store(context.applicationContext).also { instance = it } }
    }
}

internal object LocalDataCodec {
    fun encode(data: LocalData): String {
        val s = data.settings
        val settings = JSONObject()
            .put("onboarded", s.onboarded)
            .put("provider", s.provider)
            .put("baseUrl", s.baseUrl)
            .put("cleanupModel", s.cleanupModel)
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
        return JSONObject().put("version", 3).put("settings", settings)
            .put("dictionary", JSONArray(data.dictionary))
            .put("snippets", JSONArray(data.snippets.map { JSONObject().put("id",it.id).put("trigger",it.trigger).put("expansion",it.expansion) }))
            .put("history", JSONArray(data.history.map { JSONObject().put("id",it.id).put("createdAt",it.createdAt).put("raw",it.raw).put("text",it.text).put("note",it.note).put("durationMs",it.durationMs).put("revision",it.revision) }))
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
        val version = root.getInt("version"); require(version in 1..3) { "Unsupported local schema" }
        val s = root.getJSONObject("settings"); val d = Settings()
        // Reject malformed known fields instead of opt* silently reusing defaults.
        require(!s.has("onboarded") || s.get("onboarded") is Boolean)
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
        val settings = Settings(
            onboarded = if(s.has("onboarded")) s.getBoolean("onboarded") else d.onboarded,
            provider = if(version == 1) "openai-compatible" else if(s.has("provider")) s.getString("provider") else d.provider,
            baseUrl = if(s.has("baseUrl")) s.getString("baseUrl") else if(version == 1) "https://api.openai.com/v1" else d.baseUrl,
            cleanupModel = if(s.has("cleanupModel")) s.getString("cleanupModel") else if(version == 1) "gpt-4.1-mini" else d.cleanupModel,
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
        )
        if(settings.provider != "apple-intelligence") canonicalEndpoint(settings)
        require(settings.cleanupModel.isNotBlank())
        require(settings.language == "auto" || settings.language in SpeechLanguages.codes)
        require(settings.recoveryAudioDays in 1..30)
        require(settings.historyLimit in 1..1000 && settings.style in setOf("standard","conversational","formal") && settings.outputMode in setOf("cleanup","raw","selectedPreset"))
        require(settings.provider in setOf("anthropic","openai-compatible","apple-intelligence"))
        require(settings.bubbleSize.isFinite() && settings.bubbleSize in .7f..1.5f && settings.bubbleOpacity.isFinite() && settings.bubbleOpacity in .2f..1f)
        val words = strings(root,"dictionary"); require(words.size <= 1000)
        val snippets = objects(root,"snippets").map { Snippet(it.getString("id"),it.getString("trigger"),it.getString("expansion")) }
        val history = objects(root,"history").map { HistoryEntry(it.getString("id"),it.getLong("createdAt"),it.getString("raw"),it.getString("text"),it.optString("note"),it.optLong("durationMs"),it.optLong("revision")) }
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
