package dev.appless.app.platform

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import dev.appless.genoscore.SecureStore
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * The Android half of `genos-core`'s [SecureStore] seam — the RN app's
 * `expo-secure-store`.
 *
 * The BYOK Cerebras key is the one secret AppLess holds, so it is stored in
 * `EncryptedSharedPreferences`: the payload is AES-256-GCM encrypted under a
 * master key that lives in the **Android Keystore** (hardware-backed where the
 * device has a TEE/StrongBox) and never leaves it. A rooted-device file dump
 * yields ciphertext.
 *
 * `genos-core` is single-threaded by contract but its seam is `suspend`, so
 * both the (blocking) Keystore unwrap and every read/write hop to
 * [Dispatchers.IO] — the caller's dispatcher is never blocked.
 */
public class AndroidSecureStore(context: Context) : SecureStore {

    private val appContext = context.applicationContext

    /**
     * Built lazily and once: `MasterKey.Builder` talks to the Keystore, which
     * is slow enough to matter on the first frame.
     */
    private val prefs: SharedPreferences by lazy {
        val masterKey = MasterKey.Builder(appContext, MasterKey.DEFAULT_MASTER_KEY_ALIAS)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            appContext,
            FILE_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    override suspend fun read(key: String): String? = withContext(Dispatchers.IO) {
        prefs.getString(key, null)
    }

    /**
     * `null` deletes, matching the seam's contract (`KeyStore.markRejected`
     * writes null to wipe a rejected key).
     */
    override suspend fun write(key: String, value: String?): Unit = withContext(Dispatchers.IO) {
        prefs.edit().apply {
            if (value == null) remove(key) else putString(key, value)
        }.apply()
    }

    private companion object {
        const val FILE_NAME = "appless.secure"
    }
}

/**
 * Plaintext fallback used only when the Keystore is unavailable (an emulator
 * image with no keystore provider, or a device whose key material was
 * invalidated by a lock-screen change).
 *
 * Losing the key gate entirely would brick the app, so degrading is better
 * than crashing — but it degrades LOUDLY: [isSecure] is false and the shell
 * can surface it.
 */
public class PlaintextSecureStore(context: Context) : SecureStore {
    private val prefs = context.applicationContext
        .getSharedPreferences("appless.insecure", Context.MODE_PRIVATE)

    override suspend fun read(key: String): String? = withContext(Dispatchers.IO) {
        prefs.getString(key, null)
    }

    override suspend fun write(key: String, value: String?): Unit = withContext(Dispatchers.IO) {
        prefs.edit().apply { if (value == null) remove(key) else putString(key, value) }.apply()
    }
}

/** [AndroidSecureStore], falling back to [PlaintextSecureStore] on Keystore failure. */
public class ResilientSecureStore(context: Context) : SecureStore {
    private val encrypted = AndroidSecureStore(context)
    private val plaintext = PlaintextSecureStore(context)

    /** False once the Keystore has failed and the plaintext store took over. */
    public var isSecure: Boolean = true
        private set

    override suspend fun read(key: String): String? {
        if (isSecure) {
            try {
                return encrypted.read(key)
            } catch (e: kotlin.coroutines.cancellation.CancellationException) {
                throw e
            } catch (_: Throwable) {
                isSecure = false
            }
        }
        return plaintext.read(key)
    }

    override suspend fun write(key: String, value: String?) {
        if (isSecure) {
            try {
                encrypted.write(key, value)
                return
            } catch (e: kotlin.coroutines.cancellation.CancellationException) {
                throw e
            } catch (_: Throwable) {
                isSecure = false
            }
        }
        plaintext.write(key, value)
    }
}
