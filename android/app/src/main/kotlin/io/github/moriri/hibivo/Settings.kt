package io.github.moriri.hibivo

import android.content.Context
import android.content.SharedPreferences
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.core.content.edit
import androidx.preference.PreferenceDataStore
import io.github.moriri.hibivo.core.CleanupMode
import io.github.moriri.hibivo.core.CleanupProviderKind
import io.github.moriri.hibivo.core.VocabularyEntry
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Everything the user configures except secrets, which live in [SecretStore]. */
class Settings(context: Context) {
    val preferences: SharedPreferences = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    val sttProvider: String get() = preferences.getString(STT_PROVIDER, null) ?: STT_ANDROID

    /** BCP-47 primary language of what the user dictates: "ja" or "en". */
    val language: String get() = preferences.getString(LANGUAGE, null) ?: "ja"

    var mode: CleanupMode
        get() = CleanupMode.fromId(preferences.getString(MODE, null)) ?: CleanupMode.NATURAL
        set(value) = preferences.edit { putString(MODE, value.id) }

    val cleanupProvider: CleanupProviderKind
        get() = CleanupProviderKind.fromId(preferences.getString(CLEANUP_PROVIDER, null)) ?: CleanupProviderKind.ANTHROPIC

    /** The model for `kind`: what the user entered, or the provider's default when left empty. */
    fun cleanupModel(kind: CleanupProviderKind): String =
        preferences.getString(cleanupModelKey(kind), null)?.trim().takeUnless { it.isNullOrEmpty() } ?: kind.defaultModel

    val openAIBaseUrl: String
        get() = preferences.getString(OPENAI_BASE_URL, null)?.trim().takeUnless { it.isNullOrEmpty() }
            ?: CleanupProviderKind.DEFAULT_OPENAI_BASE_URL

    val customInstructions: String get() = preferences.getString(CUSTOM_INSTRUCTIONS, null) ?: ""

    val haptics: Boolean get() = preferences.getBoolean(HAPTICS, true)

    companion object {
        const val STT_PROVIDER = "stt_provider"
        const val STT_ANDROID = "android"
        const val STT_SONIOX = "soniox"
        const val LANGUAGE = "language"
        const val MODE = "cleanup_mode"
        const val CLEANUP_PROVIDER = "cleanup_provider"
        const val OPENAI_BASE_URL = "openai_base_url"
        const val CUSTOM_INSTRUCTIONS = "custom_instructions"
        const val HAPTICS = "haptics"

        /** Preference keys with this prefix are stored in [SecretStore]; the rest is the account name. */
        const val SECRET_PREFIX = "secret."
        const val SECRET_SONIOX = "soniox"

        fun cleanupModelKey(kind: CleanupProviderKind) = "cleanup_model_${kind.id}"
        fun secretKey(account: String) = SECRET_PREFIX + account
    }
}

/**
 * API keys, encrypted with a key that never leaves the Android Keystore. The ciphertext sits in a private
 * preferences file; without the device's Keystore it can't be read.
 */
class SecretStore(context: Context) {
    private val preferences = context.getSharedPreferences("secrets", Context.MODE_PRIVATE)

    /** Null when nothing is saved, or when the saved value can no longer be decrypted. */
    fun get(account: String): String? {
        val stored = preferences.getString(account, null) ?: return null
        return try {
            val bytes = Base64.decode(stored, Base64.NO_WRAP)
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, IV_LENGTH))
            String(cipher.doFinal(bytes, IV_LENGTH, bytes.size - IV_LENGTH), Charsets.UTF_8)
        } catch (e: GeneralSecurityException) {
            null
        } catch (e: IllegalArgumentException) {
            null
        }
    }

    /** Saves `value`, or removes the account when it is null or blank. */
    fun set(account: String, value: String?) {
        val trimmed = value?.trim()
        if (trimmed.isNullOrEmpty()) {
            preferences.edit { remove(account) }
            return
        }
        try {
            val cipher = Cipher.getInstance(TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, key())
            val bytes = cipher.iv + cipher.doFinal(trimmed.toByteArray(Charsets.UTF_8))
            preferences.edit { putString(account, Base64.encodeToString(bytes, Base64.NO_WRAP)) }
        } catch (e: GeneralSecurityException) {
            // Never fall back to storing the key in the clear; the field simply stays unset.
        }
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        (keyStore.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build(),
        )
        return generator.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val ALIAS = "hibivo-secrets"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_LENGTH = 12
    }
}

/** Backs the settings screen: secret keys go to [SecretStore], everything else to [Settings]. */
class AppPreferenceDataStore(private val settings: Settings, private val secrets: SecretStore) : PreferenceDataStore() {
    override fun getString(key: String, defValue: String?): String? =
        if (key.startsWith(Settings.SECRET_PREFIX)) secrets.get(key.removePrefix(Settings.SECRET_PREFIX)) ?: defValue
        else settings.preferences.getString(key, defValue)

    override fun putString(key: String, value: String?) {
        if (key.startsWith(Settings.SECRET_PREFIX)) secrets.set(key.removePrefix(Settings.SECRET_PREFIX), value)
        else settings.preferences.edit { putString(key, value) }
    }

    override fun getBoolean(key: String, defValue: Boolean): Boolean = settings.preferences.getBoolean(key, defValue)

    override fun putBoolean(key: String, value: Boolean) = settings.preferences.edit { putBoolean(key, value) }
}

/** The user dictionary, kept as a small JSON file in the app's private storage. */
class VocabularyStore(context: Context) {
    private val file = File(context.filesDir, "vocabulary.json")

    fun load(): List<VocabularyEntry> {
        if (!file.exists()) return emptyList()
        return try {
            val array = JSONArray(file.readText())
            (0 until array.length()).mapNotNull { index ->
                val item = array.optJSONObject(index) ?: return@mapNotNull null
                val preferred = item.optString("preferred").trim()
                if (preferred.isEmpty()) return@mapNotNull null
                val spoken = item.optJSONArray("spoken")
                VocabularyEntry(
                    preferred = preferred,
                    spoken = (0 until (spoken?.length() ?: 0)).map { spoken!!.optString(it) }.filter { it.isNotBlank() },
                    isEnabled = item.optBoolean("enabled", true),
                )
            }
        } catch (e: org.json.JSONException) {
            emptyList()
        } catch (e: java.io.IOException) {
            emptyList()
        }
    }

    fun save(entries: List<VocabularyEntry>) {
        val array = JSONArray()
        for (entry in entries) {
            array.put(
                JSONObject()
                    .put("preferred", entry.preferred)
                    .put("spoken", JSONArray(entry.spoken))
                    .put("enabled", entry.isEnabled),
            )
        }
        // Write beside the file and rename, so a crash mid-write can't leave half a dictionary.
        val temporary = File(file.parentFile, file.name + ".tmp")
        try {
            temporary.writeText(array.toString())
            if (!temporary.renameTo(file)) temporary.delete()
        } catch (e: java.io.IOException) {
            temporary.delete()
        }
    }
}
