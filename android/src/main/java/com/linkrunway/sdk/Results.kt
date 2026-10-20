package com.linkrunway.sdk

import org.json.JSONObject
import java.util.Date

enum class MatchMethod {
    REFERRER,
    PROBABILISTIC,
    VIEW_THROUGH,
    NONE,

    /** A method added by a server newer than this SDK. */
    UNKNOWN,
}

/**
 * How the server resolved this install's first launch. The signed click token is not part of the
 * result: read it with [LinkRunway.attributionToken].
 */
data class InstallMatchResult(
    val matched: Boolean,
    val method: MatchMethod,
    val clickId: String? = null,
    /** The in-app path of the matched link. Route only to paths your app allowlists. */
    val path: String? = null,
    val url: String? = null,
    val metadata: Map<String, Any?> = emptyMap(),
    /** True when the answer was stored by an earlier call and no request was made. */
    val cached: Boolean = false,
)

/** What [LinkRunway.submitReferrerClaim] did. Failures are reported here instead of being thrown. */
data class ReferrerClaimResult(
    val status: Status,
    /** The server's answer per ad network, for example `GOOGLE_ADS` to `RECORDED`; empty if it found no evidence. */
    val networks: Map<String, String> = emptyMap(),
    val error: Throwable? = null,
) {
    enum class Status {
        /** The server gave its final answer for this install's referrer. */
        SUBMITTED,

        /** An earlier call completed for this install; nothing was sent. */
        ALREADY_SUBMITTED,

        /** A network has not reported the click yet. A later call sends the referrer again, no sooner than the server asked. */
        PENDING,

        /** Play reported no install referrer, so there is nothing to claim. */
        NO_REFERRER,

        /** The request failed; [error] says why. The next call tries again. */
        FAILED,
    }
}

/** What [LinkRunway.attest] did. Failures are reported here instead of being thrown. */
data class AttestationResult(
    val status: Status,
    /** When the attestation stops being attached to events. */
    val expiresAt: Date? = null,
    /** True when a still-valid attestation was reused without contacting the provider or the server. */
    val cached: Boolean = false,
    val error: Throwable? = null,
) {
    enum class Status {
        /** Events sent until [expiresAt] carry the attestation. */
        ATTESTED,

        /** No [AttestationProvider] was given to the SDK. */
        NO_PROVIDER,

        /**
         * The app's attestation mode in the LinkRunway console is OFF. Nothing more is requested
         * for this app until the process restarts; events are sent unattested.
         */
        OFF,

        /** The provider or the server refused; [error] says why. Events are still sent, unattested. */
        FAILED,
    }
}

/** `optString` reports JSON null as the text "null"; this returns a real null instead. */
internal fun JSONObject.text(name: String): String? =
    if (isNull(name)) null else optString(name).takeIf { it.isNotEmpty() }

internal fun installMatch(json: JSONObject, cached: Boolean): InstallMatchResult {
    val metadata = json.optJSONObject("metadata")
    return InstallMatchResult(
        matched = json.optBoolean("matched"),
        method = json.text("method")?.let { name -> MatchMethod.entries.firstOrNull { it.name == name } ?: MatchMethod.UNKNOWN }
            ?: MatchMethod.NONE,
        clickId = json.text("clickId"),
        path = json.text("path"),
        url = json.text("url"),
        metadata = metadata?.keys()?.asSequence()?.associateWith { key ->
            metadata.opt(key).takeUnless { it == JSONObject.NULL }
        }.orEmpty(),
        cached = cached,
    )
}

/** `{ claims: [{ provider, status }] }` as provider to status. */
internal fun claimedNetworks(json: JSONObject): Map<String, String> {
    val claims = json.optJSONArray("claims") ?: return emptyMap()
    return (0 until claims.length()).mapNotNull { claims.optJSONObject(it) }
        .mapNotNull { claim -> claim.text("provider")?.let { provider -> claim.text("status")?.let { provider to it } } }
        .toMap()
}
