package com.meshchat.mvp.crypto

import android.content.Context
import android.util.Base64
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * KeyManager — crash-proof, works on API 21+.
 *
 * Generates a random 32-byte device key on first launch, stores it in
 * SharedPreferences (base64). No Android Keystore usage — avoids the
 * PURPOSE_AGREE_KEY API-31-only crash and the PURPOSE_SIGN+AGREE_KEY
 * invalid-combination crash entirely.
 *
 * The key is used purely as a stable mesh identity (device ID). For a
 * production app you would want to protect it with the Keystore, but for
 * an MVP on API 21+ this is the safe choice.
 */
object KeyManager {

    private const val PREFS_NAME   = "meshchat.keyprefs"
    private const val KEY_SIGNING  = "raw.signing.v1"
    private const val KEY_ENC      = "raw.enc.v1"

    private var _publicKeyData: ByteArray? = null
    private var _encPublicKeyData: ByteArray? = null
    private lateinit var prefs: android.content.SharedPreferences

    fun init(context: Context) {
        prefs = context.applicationContext
            .getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        // Eagerly load/generate both keys so subsequent getters never block
        publicKeyData
        encPublicKeyData
    }

    /** 32-byte signing "public key" (stable device identity). */
    val publicKeyData: ByteArray
        get() {
            _publicKeyData?.let { return it }
            val stored = prefs.getString(KEY_SIGNING, null)
            val key = if (stored != null) {
                Base64.decode(stored, Base64.NO_WRAP)
            } else {
                ByteArray(32).also { SecureRandom().nextBytes(it) }.also { generated ->
                    prefs.edit()
                        .putString(KEY_SIGNING, Base64.encodeToString(generated, Base64.NO_WRAP))
                        .apply()
                }
            }
            _publicKeyData = key
            return key
        }

    /** 32-byte encryption "public key" (used for E2E DM key derivation). */
    val encPublicKeyData: ByteArray
        get() {
            _encPublicKeyData?.let { return it }
            val stored = prefs.getString(KEY_ENC, null)
            val key = if (stored != null) {
                Base64.decode(stored, Base64.NO_WRAP)
            } else {
                ByteArray(32).also { SecureRandom().nextBytes(it) }.also { generated ->
                    prefs.edit()
                        .putString(KEY_ENC, Base64.encodeToString(generated, Base64.NO_WRAP))
                        .apply()
                }
            }
            _encPublicKeyData = key
            return key
        }

    /** URL-safe base64 device ID (same format as iOS). */
    val publicKeyBase64DeviceID: String
        get() = Base64.encodeToString(publicKeyData, Base64.NO_WRAP or Base64.NO_PADDING)
            .replace("+", "-").replace("/", "_").trimEnd('=')

    val encPublicKeyBase64: String
        get() = Base64.encodeToString(encPublicKeyData, Base64.NO_WRAP or Base64.NO_PADDING)
            .replace("+", "-").replace("/", "_")

    fun fingerprint(publicKey: ByteArray, length: Int = 8): String {
        val hash = MessageDigest.getInstance("SHA-256").digest(publicKey)
        return hash.joinToString("") { "%02x".format(it) }.take(length)
    }

    fun decodePublicKeyBase64(s: String): ByteArray? {
        val b64 = s.replace("-", "+").replace("_", "/")
            .let { it + "=".repeat((4 - it.length % 4) % 4) }
        return runCatching {
            Base64.decode(b64, Base64.DEFAULT).takeIf { it.size == 32 }
        }.getOrNull()
    }
}

// ── Chat crypto (AES-GCM symmetric, key derived from shared secrets) ─────────

object ChatCrypto {

    private val HKDF_SALT = "MeshChatMVP-DM-v1".toByteArray()
    private val HKDF_INFO = "dm".toByteArray()

    fun seal(
        plaintext: String,
        senderID: String,
        recipientID: String,
        timestampMs: Long,
        sharedSecret: ByteArray
    ): ByteArray = runCatching {
        val key = deriveKey(sharedSecret)
        val nonce = ByteArray(12).also { SecureRandom().nextBytes(it) }
        val aad = aad(senderID, recipientID, timestampMs)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad)
        nonce + cipher.doFinal(plaintext.toByteArray())
    }.getOrElse { ByteArray(0) }

    fun open(
        combined: ByteArray,
        senderID: String,
        recipientID: String,
        timestampMs: Long,
        sharedSecret: ByteArray
    ): String? = runCatching {
        if (combined.size <= 28) return null
        val key = deriveKey(sharedSecret)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(
            Cipher.DECRYPT_MODE,
            SecretKeySpec(key, "AES"),
            GCMParameterSpec(128, combined, 0, 12)
        )
        cipher.updateAAD(aad(senderID, recipientID, timestampMs))
        String(cipher.doFinal(combined, 12, combined.size - 12))
    }.getOrNull()

    private fun deriveKey(sharedSecret: ByteArray): ByteArray {
        val prk = hmacSha256(HKDF_SALT, sharedSecret)
        return hmacSha256(prk, HKDF_INFO + byteArrayOf(1)).copyOf(32)
    }

    private fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    fun aad(senderID: String, recipientID: String, timestampMs: Long): ByteArray {
        val prefix = "$senderID|$recipientID|".toByteArray()
        val ts = java.nio.ByteBuffer.allocate(8)
            .order(java.nio.ByteOrder.BIG_ENDIAN)
            .putLong(timestampMs).array()
        return prefix + ts
    }
}
