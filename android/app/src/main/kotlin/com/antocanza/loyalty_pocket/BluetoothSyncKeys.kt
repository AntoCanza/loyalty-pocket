package com.antocanza.loyalty_pocket

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

internal class BluetoothSyncKeys(context: Context) {
    private val preferences = context.getSharedPreferences("bluetooth_sync_keys", Context.MODE_PRIVATE)

    fun read(): ByteArray? {
        val encoded = preferences.getString(PREFERENCE, null) ?: return null
        val record = Base64.decode(encoded, Base64.NO_WRAP)
        check(record.size == IV_SIZE + KEY_SIZE + TAG_BITS / Byte.SIZE_BITS)
        val secret = checkNotNull(openKeystore().getKey(ALIAS, null) as? SecretKey)
        val cipher = Cipher.getInstance(CIPHER)
        cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(TAG_BITS, record, 0, IV_SIZE))
        return cipher.doFinal(record, IV_SIZE, record.size - IV_SIZE).also { check(it.size == KEY_SIZE) }
    }

    fun write(value: ByteArray?) {
        if (value == null) {
            check(preferences.edit().remove(PREFERENCE).commit())
            openKeystore().deleteEntry(ALIAS)
            return
        }
        check(value.size == KEY_SIZE)
        val secret = openKeystore().getKey(ALIAS, null) as? SecretKey ?: createKey()
        val cipher = Cipher.getInstance(CIPHER)
        cipher.init(Cipher.ENCRYPT_MODE, secret)
        check(cipher.iv.size == IV_SIZE)
        val encoded = Base64.encodeToString(cipher.iv + cipher.doFinal(value), Base64.NO_WRAP)
        check(preferences.edit().putString(PREFERENCE, encoded).commit())
    }

    private fun openKeystore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    private fun createKey(): SecretKey = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        .apply {
            init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setKeySize(256)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build())
        }.generateKey()

    companion object {
        const val KEY_SIZE = 32
        private const val KEYSTORE = "AndroidKeyStore"
        private const val ALIAS = "loyalty_pocket_ble_group_key_v1"
        private const val PREFERENCE = "encrypted_group_key_v1"
        private const val CIPHER = "AES/GCM/NoPadding"
        private const val IV_SIZE = 12
        private const val TAG_BITS = 128
    }
}
