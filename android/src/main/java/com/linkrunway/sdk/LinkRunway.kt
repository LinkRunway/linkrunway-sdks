package com.linkrunway.sdk

import android.content.Context
import android.net.Uri
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.UUID

/**
 * The LinkRunway client for Android phones, tablets and Android TV.
 *
 * Nothing is sent, read or stored until [setConsent] is called with `true`, and withdrawing consent
 * erases what the SDK kept. Only publishable keys (`lr_pk_`) are accepted: revenue is reported by
 * your server. Network calls suspend, so call them from a coroutine.
 */
class LinkRunway internal constructor(
    context: Context,
    endpoint: String,
    publishableKey: String,
    attestation: AttestationProvider?,
    transport: HttpTransport,
    referrer: suspend (Context) -> String?,
    now: () -> Long,
) {
    /**
     * @param attestation produces device integrity tokens for [attest], for example
     *   [PlayIntegrityAttestation]. Without one the SDK never touches Play services for attestation.
     * @param transport executes the SDK's HTTPS requests; the default uses `HttpURLConnection`.
     */
    @JvmOverloads
    constructor(
        context: Context,
        endpoint: String,
        publishableKey: String,
        attestation: AttestationProvider? = null,
        transport: HttpTransport = UrlConnectionTransport(),
    ) : this(context, endpoint, publishableKey, attestation, transport, { playReferrer(it) }, System::currentTimeMillis)

    private val platform = Device.platform(context)
    private val session = Session(Store(context, endpoint, publishableKey), now)
    private val api = ApiClient(endpoint, publishableKey, Device.userAgent(platform), transport) { session.consent }
    private val source = ReferrerSource(session, referrer)
    private val launch = FirstLaunch(session, api, platform, source)
    private val claims = ReferrerClaims(context.applicationContext ?: context, session, api, source, now)
    private val attestor = Attestor(session, api, attestation, now)

    fun setConsent(value: Boolean) {
        session.setConsent(value)
        if (!value) {
            source.forget()
            attestor.forget()
        }
    }

    fun captureReferrer(referrer: String) = session.captureReferrer(referrer)

    fun attributionToken(): String? = if (session.consent) session.clickToken else null

    /**
     * A random UUID created by the SDK for this install and sent with its events, or null without
     * consent. It is not the advertising ID or any device identifier, and it does not survive a
     * reinstall or a consent withdrawal.
     */
    fun installId(): String? = session.installId()

    suspend fun open(url: String): JSONObject? {
        if (!session.consent) return null
        Uri.parse(url).getQueryParameter("lr_token")?.let { session.captureToken(it); return null }
        // The resolve endpoint accepts ios, android and web, so an Android TV open is reported as android.
        val result = api.post("resolve", JSONObject().put("url", url).put("consent", true).put("platform", "android"))
        if (!session.consent) return null
        // Over the plan's click allowance the link still routes but no click is recorded: that
        // answer leaves the current attribution as it was.
        if (!result.optBoolean("untracked")) session.saveToken(result.text("clickToken"))
        return result
    }

    suspend fun track(type: String, eventId: String = UUID.randomUUID().toString(), userId: String? = null,
                      metadata: JSONObject = JSONObject(), occurredAt: Date = Date()): JSONObject? =
        event(type, eventId, userId, metadata, occurredAt, null)

    private suspend fun event(type: String, eventId: String, userId: String?, metadata: JSONObject,
                              occurredAt: Date, fallbackToken: String?): JSONObject? {
        if (!session.consent) return null
        require(type in listOf("INSTALL", "OPEN", "SIGNUP", "CUSTOM")) { "Revenue must be verified on your server" }
        val timestamp = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(occurredAt)
        return api.post("track", JSONObject().put("eventId", eventId).put("type", type)
            .put("clickToken", session.clickToken ?: fallbackToken).put("externalUserId", userId)
            .put("metadata", metadata).put("consent", true).put("occurredAt", timestamp)
            .put("installId", session.installId()).put("attestation", session.attestation()?.token))
    }

    suspend fun createShare(linkId: String, userId: String? = null, channel: String = "native_share"): JSONObject {
        check(session.consent) { "Consent is required for tracked sharing" }
        return api.post("shares", JSONObject().put("linkId", linkId).put("externalUserId", userId).put("channel", channel))
    }

    /**
     * Resolves this install's first launch on the server: a LinkRunway token in the Play install
     * referrer first, then whatever probabilistic or view-through matching the workspace owner
     * enabled. A matched click's token is kept for later events unless a link opened since has
     * already set one. The answer is stored, so the server is asked once per install; later calls
     * return it with `cached` set and make no request.
     *
     * Returns null without consent. Throws when Play cannot be read for the referrer or the request
     * fails; nothing is stored then, so the next call tries again.
     */
    suspend fun matchInstall(context: Context): InstallMatchResult? = launch.match(context, strict = true).match

    /** The answer [matchInstall] can give without a request, or null while the server still has to be asked. */
    fun installMatch(): InstallMatchResult? = launch.stored()

    /**
     * Reports the INSTALL event once per install, after resolving the first launch as
     * [matchInstall] does. A failed match request never stops the event: the SDK then falls back to
     * the LinkRunway token in the Play install referrer, as earlier versions did. When Play itself
     * cannot be read for the referrer, or INSTALL cannot be delivered, this throws and the next
     * call starts again with the same event ID. Call it on every app start; once INSTALL is
     * delivered it returns null without a request.
     */
    suspend fun install(context: Context): JSONObject? {
        if (!session.consent) return null
        if (session.store.installSent) return null
        val eventId = session.store.installEventId()
        val fallback = launch.match(context, strict = false).fallbackToken
        val result = event("INSTALL", eventId, null, JSONObject(), Date(), fallback)
        if (result != null && session.consent) {
            session.store.markInstallSent()
            // The server accepted the event that carried it, so the referrer's token is kept from here on.
            session.adoptToken(fallback)
        }
        return result
    }

    /**
     * Sends the raw Play install referrer to the server so it can verify the ad-network evidence
     * inside it (Meta's encrypted payload, a Google click ID). [appId] is the app's ID in the
     * LinkRunway console. One final answer is recorded per install; while a network has not
     * reported the click yet the result is `PENDING` and a later call sends the referrer again.
     *
     * Returns null without consent and never throws for a network or server failure, so it cannot
     * break [install] whichever is called first.
     */
    suspend fun submitReferrerClaim(appId: String): ReferrerClaimResult? = claims.submit(appId)

    /**
     * Proves to the server that this is a genuine install of your app on a genuine device: server
     * challenge, token from the [AttestationProvider], exchange for a server attestation. That
     * attestation is cached until it expires and attached to every [track] call until then.
     *
     * Returns null without consent and reports failures in the result rather than throwing: events
     * are still sent without an attestation. A valid cached attestation is reused, not renewed, so
     * calling this on every app start is cheap.
     */
    suspend fun attest(appId: String): AttestationResult? = attestor.attest(appId)

    suspend fun createReferralCode(): JSONObject? {
        check(session.consent && session.clickToken != null) { "A consented attributed click is required" }
        val result = api.post("deferred", JSONObject().put("clickToken", session.clickToken).put("consent", true))
        return if (session.consent) result else null
    }

    suspend fun claimReferralCode(code: String, claimId: UUID): JSONObject? {
        if (!session.consent) return null
        val result = api.post("deferred/claim", JSONObject().put("code", code).put("claimId", claimId.toString()).put("consent", true))
        if (!session.consent) return null
        session.saveToken(result.getString("clickToken"))
        return result
    }

    companion object {
        /** The SDK version reported in the `LinkRunwaySDK/<version>` user agent. */
        const val VERSION = "0.2.0"
    }
}
