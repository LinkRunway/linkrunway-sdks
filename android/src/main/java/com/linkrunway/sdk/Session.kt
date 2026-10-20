package com.linkrunway.sdk

import android.net.Uri
import org.json.JSONException
import org.json.JSONObject
import java.util.UUID

/** A server-issued attestation token, valid for one app and one install until [expiresAt]. */
internal class StoredAttestation(val appId: String, val installId: String, val token: String, val expiresAt: Long) {
    fun json(): String = JSONObject().put("appId", appId).put("installId", installId)
        .put("token", token).put("expiresAt", expiresAt).toString()

    companion object {
        fun parse(text: String?): StoredAttestation? = try {
            text?.let(::JSONObject)?.let {
                StoredAttestation(it.getString("appId"), it.getString("installId"), it.getString("token"), it.getLong("expiresAt"))
            }
        } catch (error: JSONException) { null }
    }
}

/**
 * Everything the SDK remembers, in memory and on disk. Nothing is read, created or written while
 * consent is off, and withdrawing consent erases it. Mutations share one lock with withdrawal, so a
 * response that arrives after consent was withdrawn can never be stored.
 */
internal class Session(val store: Store, private val now: () -> Long) {
    @Volatile var consent = false
        private set
    @Volatile var clickToken: String? = null
        private set
    @Volatile private var install: String? = null
    @Volatile private var attestation: StoredAttestation? = null

    fun setConsent(value: Boolean) = synchronized(this) {
        consent = value
        if (value) {
            store.discardIfRestored()
            clickToken = store.token
            install = store.installId
            attestation = StoredAttestation.parse(store.attestation)
        } else {
            clickToken = null
            install = null
            attestation = null
            store.forget()
        }
    }

    /**
     * A random UUID created on first use. It is not derived from the device and is unrelated to the
     * advertising ID; withdrawing consent deletes it, and a later grant starts a new one.
     */
    fun installId(): String? = synchronized(this) {
        if (!consent) null
        else install ?: UUID.randomUUID().toString().also { install = it; store.installId = it }
    }

    fun saveToken(token: String?) {
        synchronized(this) {
            if (!consent) return
            clickToken = token
            store.token = token
        }
    }

    /** A token from a URL or referrer is untrusted input: one the server could never accept is ignored. */
    fun captureToken(token: String) {
        if (plausible(token)) saveToken(token)
    }

    /** Keeps the signed click token a LinkRunway store link placed in the Play install referrer. */
    fun captureReferrer(referrer: String) {
        if (consent) referrerToken(referrer)?.let(::saveToken)
    }

    /** Takes the install's token unless a link opened since has set one: the latest touch stays. */
    fun adoptToken(token: String?) {
        synchronized(this) { if (token != null && clickToken == null) captureToken(token) }
    }

    /**
     * Runs [write] only if consent is still on and [installId] is still this install's ID. Returns
     * null when the answer belongs to an identity the user has since withdrawn.
     */
    fun <T> commit(installId: String, write: () -> T): T? =
        synchronized(this) { if (consent && install == installId) write() else null }

    fun saveAttestation(value: StoredAttestation) = commit(value.installId) {
        attestation = value
        store.attestation = value.json()
    }

    /** The cached attestation for this install while it has at least a minute left. */
    fun attestation(appId: String? = null): StoredAttestation? = attestation?.takeIf {
        consent && it.installId == install && (appId == null || it.appId == appId) && now() < it.expiresAt - EXPIRY_MARGIN
    }

    companion object {
        const val EXPIRY_MARGIN = 60_000L
        const val TOKEN_LIMIT = 1500

        fun plausible(token: String) = token.isNotEmpty() && token.length <= TOKEN_LIMIT

        /** The LinkRunway click token inside a Play install referrer, if it carries a usable one. */
        fun referrerToken(referrer: String): String? =
            Uri.parse("https://referrer.invalid/?$referrer").getQueryParameter("lr_token")?.takeIf(::plausible)
    }
}
