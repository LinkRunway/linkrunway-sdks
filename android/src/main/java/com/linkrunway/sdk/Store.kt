package com.linkrunway.sdk

import android.content.Context
import java.io.File
import java.util.UUID
import kotlin.properties.ReadWriteProperty
import kotlin.reflect.KProperty

/**
 * The SDK's private SharedPreferences file. Keys are scoped to one endpoint and publishable key, so
 * two workspaces in one app never share state. The token and INSTALL key names predate this class:
 * changing them would make upgraded apps report their install a second time.
 */
internal class Store(context: Context, endpoint: String, publishableKey: String) {
    private val preferences = context.getSharedPreferences("linkrunway", Context.MODE_PRIVATE)
    private val sentinel by lazy { File((context.applicationContext ?: context).noBackupFilesDir, "linkrunway") }
    private val scope = "$endpoint:${publishableKey.take(20)}"
    private val installEventKey = "install:token:$scope"

    var token by Text("token:$scope")
    /** A random UUID for this install. It exists only while consent is on. */
    var installId by Text("installId:$scope")
    /** The first-launch match outcome as JSON, without the click token. */
    var match by Text("match:$scope")
    var attestation by Text("attestation:$scope")
    private var installEvent by Text(installEventKey)
    /** While a claim is pending: when it was first sent, and the earliest time to send it again. */
    var claimPendingSince by Time("claim:$scope:since")
    var claimRetryAt by Time("claim:$scope:retryAt")

    // One-shot markers. They are booleans, identify nothing, and outlive a consent withdrawal so
    // that one installation is never reported, matched or claimed twice.
    var installSent by Flag("$installEventKey:sent")
    var matchResolved by Flag("match:$scope:resolved")
    var claimSent by Flag("claim:$scope:sent")

    /** The INSTALL event's ID, stable across retries so the server can deduplicate the event. */
    fun installEventId(): String = installEvent ?: UUID.randomUUID().toString().also { installEvent = it }

    /** The delivered marker is all that outlives the event; its ID has no further use. */
    fun markInstallSent() {
        installSent = true
        installEvent = null
    }

    fun markClaimSent() {
        claimSent = true
        claimPendingSince = 0
        claimRetryAt = 0
    }

    /**
     * Android's Auto Backup and device-to-device transfer copy this file to other installs, where
     * its install ID, click token and markers would describe someone else's install. A file in the
     * no-backup directory is never copied, so state that arrives without that file is discarded.
     */
    fun discardIfRestored() {
        if (preferences.getBoolean(GUARD, false) && !sentinel.exists()) preferences.edit().clear().apply()
    }

    // The guard is set only once this install's own no-backup file is known to exist, so a device
    // where that file cannot be created never mistakes its own state for a restored one.
    private fun guard() {
        if (preferences.getBoolean(GUARD, false)) return
        val present = try {
            sentinel.exists() || sentinel.createNewFile()
        } catch (error: Exception) { false }
        if (present) preferences.edit().putBoolean(GUARD, true).apply()
    }

    /** Consent withdrawal erases every stored value; only the one-shot markers remain. */
    fun forget() {
        token = null
        installId = null
        match = null
        attestation = null
        installEvent = null
        claimPendingSince = 0
        claimRetryAt = 0
    }

    private inner class Text(private val key: String) : ReadWriteProperty<Any?, String?> {
        override fun getValue(thisRef: Any?, property: KProperty<*>): String? = preferences.getString(key, null)
        override fun setValue(thisRef: Any?, property: KProperty<*>, value: String?) {
            if (value != null) guard()
            preferences.edit().run { if (value == null) remove(key) else putString(key, value) }.apply()
        }
    }

    private inner class Flag(private val key: String) : ReadWriteProperty<Any?, Boolean> {
        override fun getValue(thisRef: Any?, property: KProperty<*>): Boolean = preferences.getBoolean(key, false)
        override fun setValue(thisRef: Any?, property: KProperty<*>, value: Boolean) {
            guard()
            preferences.edit().putBoolean(key, value).apply()
        }
    }

    /** Milliseconds since the epoch; zero means unset and is not stored. */
    private inner class Time(private val key: String) : ReadWriteProperty<Any?, Long> {
        override fun getValue(thisRef: Any?, property: KProperty<*>): Long = preferences.getLong(key, 0)
        override fun setValue(thisRef: Any?, property: KProperty<*>, value: Long) {
            if (value != 0L) guard()
            preferences.edit().run { if (value == 0L) remove(key) else putLong(key, value) }.apply()
        }
    }

    private companion object { const val GUARD = "guard" }
}
