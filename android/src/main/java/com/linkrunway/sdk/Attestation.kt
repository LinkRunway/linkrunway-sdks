package com.linkrunway.sdk

import android.util.Base64
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withTimeoutOrNull
import org.json.JSONObject
import java.io.IOException
import java.security.MessageDigest
import java.text.ParseException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone

/**
 * Produces a platform integrity token bound to [nonce]. The SDK ships [PlayIntegrityAttestation];
 * implement this yourself to use another Play Integrity setup. Throw to report a failure.
 */
interface AttestationProvider {
    /** [nonce] is ready to use as a classic Play Integrity nonce or a standard request hash. */
    suspend fun token(nonce: String): String
}

/**
 * Binds an integrity token to one server challenge and one install:
 * `base64url_nopad(SHA-256(utf8(challenge) + "." + utf8(installId)))`. The server recomputes it.
 */
internal fun attestationNonce(challenge: String, installId: String): String {
    val digest = MessageDigest.getInstance("SHA-256").digest("$challenge.$installId".toByteArray(Charsets.UTF_8))
    return Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_WRAP or Base64.NO_PADDING)
}

/** Milliseconds since the epoch for the server's ISO-8601 UTC timestamps. */
internal fun parseInstant(text: String): Long {
    for (pattern in listOf("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", "yyyy-MM-dd'T'HH:mm:ss'Z'")) {
        val format = SimpleDateFormat(pattern, Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
            isLenient = false
        }
        try {
            return format.parse(text)?.time ?: continue
        } catch (error: ParseException) { continue }
    }
    throw IllegalStateException("Malformed timestamp")
}

/** Challenge, provider token, exchange. One run at a time; a valid attestation is reused, not renewed. */
internal class Attestor(
    private val session: Session,
    private val api: ApiClient,
    private val provider: AttestationProvider?,
    private val now: () -> Long,
) {
    private val lock = Mutex()
    @Volatile private var refused: AttestationResult? = null
    @Volatile private var retryAt = 0L
    /** Apps whose owner turned attestation off, as the server said in this process. */
    @Volatile private var off: Set<String> = emptySet()

    fun forget() { refused = null }

    suspend fun attest(appId: String): AttestationResult? = lock.withLock {
        if (!session.consent) return null
        session.attestation(appId)?.let {
            return AttestationResult(AttestationResult.Status.ATTESTED, Date(it.expiresAt), cached = true)
        }
        val provider = provider ?: return AttestationResult(AttestationResult.Status.NO_PROVIDER)
        if (appId in off) return AttestationResult(AttestationResult.Status.OFF)
        if (appId.isBlank() || appId.length > 100) return failed(IllegalArgumentException("appId is the app's ID in the LinkRunway console"))
        // Every provider token counts against the app's integrity quota, so a device or setup that
        // was just refused waits before it spends another one.
        refused?.takeIf { retryAt - now() in 1..PAUSE }?.let { return it }
        var spent = false
        try {
            val installId = session.installId() ?: return null
            val challenge = try {
                api.post("attest/challenge", JSONObject().put("appId", appId))
            } catch (error: LinkRunwayException) {
                // 409: the owner turned attestation off for this app. That is a setting, not a
                // failure: nothing more is asked for this app until the process starts again.
                if (error.status != 409) throw error
                off = off + appId
                return if (session.consent) AttestationResult(AttestationResult.Status.OFF) else null
            }
            val nonce = attestationNonce(challenge.getString("challenge"), installId)
            spent = true
            // A provider that never answers must not hold this call, or the lock, forever.
            val token = withTimeoutOrNull(PROVIDER_TIMEOUT) { provider.token(nonce) }
                ?: throw IOException("Attestation provider timed out")
            val exchange = JSONObject().put("appId", appId).put("challengeId", challenge.getString("challengeId"))
                .put("installId", installId).put("token", token)
            // The server spends the challenge on its first look, so a server error is not retried.
            val issued = api.send("attest/play", exchange, retryServerErrors = false).json
            val stored = StoredAttestation(appId, installId, issued.getString("attestation"), parseInstant(issued.getString("expiresAt")))
            session.saveAttestation(stored) ?: return null
            refused = null
            AttestationResult(AttestationResult.Status.ATTESTED, Date(stored.expiresAt))
        } catch (error: Exception) {
            error.rethrowIfCancelled()
            failed(error, pause = spent)
        } catch (error: LinkageError) {
            // The app configured a provider whose library (for example Play Integrity) is not packaged.
            failed(error, pause = spent)
        }
    }

    // A call cut short by a consent withdrawal has nothing to report.
    private fun failed(error: Throwable, pause: Boolean = false): AttestationResult? {
        if (!session.consent) return null
        val result = AttestationResult(AttestationResult.Status.FAILED, error = error)
        if (pause) {
            refused = result
            retryAt = now() + PAUSE
        }
        return result
    }

    private companion object {
        const val PROVIDER_TIMEOUT = 60_000L
        const val PAUSE = 5 * 60_000L
    }
}
