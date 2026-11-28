package dev.parla.android

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import org.json.JSONObject

internal interface KeySealer { fun seal(plain: ByteArray): ByteArray; fun open(sealed: ByteArray): ByteArray }

/** AES-256-GCM with a non-exportable Android Keystore key: [iv size, iv, ciphertext]. */
internal object KeystoreSealer : KeySealer {
    private const val KEY_ALIAS = "parla-provider-key-v1"
    override fun seal(plain: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding"); cipher.init(Cipher.ENCRYPT_MODE, secretKey())
        return byteArrayOf(cipher.iv.size.toByte()) + cipher.iv + cipher.doFinal(plain)
    }
    override fun open(sealed: ByteArray): ByteArray {
        val ivSize = sealed[0].toInt(); require(ivSize == 12 && sealed.size > 1 + ivSize + 16)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, secretKey(), GCMParameterSpec(128, sealed.copyOfRange(1, 1 + ivSize)))
        return cipher.doFinal(sealed.copyOfRange(1 + ivSize, sealed.size))
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
}

/**
 * One encrypted file per credential scope (wire format + canonical address), so a key can only be read
 * for the address it was saved for. Files are [version, sealed payload]; the version-2 payload is
 * {"scope","key"}, identical to the pre-1.3.2 single `provider-key.enc`, which is moved once into its
 * scope's file. An unbound version-1 key is never bound automatically; it waits for an explicit Save.
 */
internal class ProviderKeys(private val dir: File, private val legacy: DurableFile, private val sealer: KeySealer) {
    private var migrated = false
    private fun file(scope: String) = DurableFile(File(dir, MessageDigest.getInstance("SHA-256").digest(scope.toByteArray()).joinToString("") { "%02x".format(it) } + ".key"))
    @Synchronized fun has(scope: String): Boolean { migrate(); return file(scope).baseFile.exists() }
    @Synchronized fun read(scope: String): String? {
        migrate()
        val bytes = file(scope).read(MAX) ?: return null
        val (bound, key) = try { decode(bytes) } catch (_: Exception) { throw IllegalStateException(UNREADABLE) }
        check(bound == scope) { UNREADABLE }
        return key
    }
    @Synchronized fun save(scope: String, key: String) {
        validateProviderKey(key); require(key.isNotEmpty())
        migrate()
        try { write(file(scope), scope, key) } catch (_: Exception) { throw IllegalStateException("Key was not saved securely. Re-enter it and save again.") }
    }
    @Synchronized fun remove(scope: String) {
        val target = file(scope); target.delete()
        check(!target.baseFile.exists()) { "Saved key could not be removed. Check device storage and try again." }
    }
    @Synchronized fun adoptLegacy(scope: String): Boolean {
        migrate()
        if (file(scope).baseFile.exists()) return false
        val (bound, key) = runCatching { decode(legacy.read(MAX)!!) }.getOrNull() ?: return false
        if (bound != UNBOUND) return false
        save(scope, key); legacy.delete(); return true
    }
    private fun migrate() {
        if (migrated) return
        try {
            val (scope, key) = legacy.read(MAX)?.let { runCatching { decode(it) }.getOrNull() } ?: run { migrated = true; return }
            if (scope == UNBOUND) { migrated = true; return }
            val target = file(scope)
            // A key already saved for this scope is newer than the legacy file.
            if (target.read(MAX)?.let { runCatching { decode(it) }.getOrNull() }?.first != scope) write(target, scope, key)
            legacy.delete(); migrated = true
        } catch (_: Exception) { /* Legacy file kept and retried on the next access. */ }
    }
    private fun write(target: DurableFile, scope: String, key: String) {
        target.write(byteArrayOf(2) + sealer.seal(JSONObject().put("scope", scope).put("key", key).toString().toByteArray()))
        check(decode(target.read(MAX)!!) == scope to key)
    }
    private fun decode(bytes: ByteArray): Pair<String, String> {
        require(bytes.size in 2..32768 && bytes[0].toInt() in 1..2)
        val plain = sealer.open(bytes.copyOfRange(1, bytes.size)).toString(Charsets.UTF_8)
        if (bytes[0].toInt() == 1) return UNBOUND to plain
        val json = JSONObject(plain); return json.getString("scope") to json.getString("key")
    }
    private companion object {
        const val MAX = 32769
        const val UNBOUND = "legacy-unbound"
        const val UNREADABLE = "Saved key cannot be unlocked. Remove it and save a key again; local speech still works."
    }
}
