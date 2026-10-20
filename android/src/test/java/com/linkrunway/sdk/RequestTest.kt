package com.linkrunway.sdk

import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.Date

/** The exact paths, headers and JSON bodies the SDK puts on the wire. */
@RunWith(RobolectricTestRunner::class)
class RequestTest {
    private val headers = mapOf(
        "User-Agent" to "LinkRunwaySDK/0.2.1 Android",
        "Content-Type" to "application/json",
        "Authorization" to "Bearer $KEY",
    )

    private fun JSONObject.fields() = keys().asSequence().toSet()

    @Test
    @Config(sdk = [23, 34])
    fun `track sends the event with the install id and the SDK headers`() = runTest {
        val h = Harness()
        h.transport.on("track") { ok("""{"id":"evt_1","attributed":false,"duplicate":false}""") }
        val sdk = h.sdk()

        val result = sdk.track("SIGNUP", "event-1", "user-9", JSONObject().put("plan", "pro"), Date(NOW + 123))

        assertEquals("evt_1", result!!.getString("id"))
        val request = h.transport.requests.single()
        assertEquals("https://go.example.com/v1/track", request.url)
        assertEquals(headers, request.headers)
        val body = JSONObject(request.body)
        assertEquals(setOf("eventId", "type", "externalUserId", "metadata", "consent", "occurredAt", "installId"), body.fields())
        assertEquals("event-1", body.getString("eventId"))
        assertEquals("SIGNUP", body.getString("type"))
        assertEquals("user-9", body.getString("externalUserId"))
        assertEquals("pro", body.getJSONObject("metadata").getString("plan"))
        assertEquals(true, body.get("consent"))
        assertEquals("2027-01-15T08:00:00.123Z", body.getString("occurredAt"))
        assertTrue(UUID_V4.matches(body.getString("installId")))
        assertEquals(sdk.installId(), body.getString("installId"))
    }

    @Test
    fun `every event of an install carries the same install id`() = runTest {
        val h = Harness()
        h.sdk().track("OPEN")
        h.sdk().track("CUSTOM")

        val ids = h.transport.bodies("track").map { it.getString("installId") }
        assertEquals(2, ids.size)
        assertEquals(1, ids.toSet().size)
        assertEquals(ids[0], h.stored("installId"))
    }

    @Test
    fun `match sends the install, platform, OS version, language and raw referrer`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { ok(MATCHED) }
        val sdk = h.sdk()

        sdk.matchInstall(h.context)

        val request = h.transport.requests.single()
        assertEquals("https://go.example.com/v1/installs/match", request.url)
        assertEquals(headers, request.headers)
        val body = JSONObject(request.body)
        assertEquals(setOf("installId", "platform", "osVersion", "language", "referrer", "consent"), body.fields())
        assertEquals(sdk.installId(), body.getString("installId"))
        assertEquals("android", body.getString("platform"))
        assertEquals("14", body.getString("osVersion"))
        assertEquals("en-US", body.getString("language"))
        assertEquals(REFERRER, body.getString("referrer"))
        assertEquals(true, body.get("consent"))
    }

    @Test
    fun `match omits the referrer when Play has none`() = runTest {
        val none = Harness(referrer = null)
        none.sdk().matchInstall(none.context)
        assertFalse(none.transport.body("installs/match").has("referrer"))
    }

    @Test
    fun `an oversized referrer is reduced to the LinkRunway token for matching`() = runTest {
        val h = Harness(referrer = "$REFERRER&utm_content=${"x".repeat(4000)}")
        h.sdk().matchInstall(h.context)
        assertEquals("lr_token=tok.referrer", h.transport.body("installs/match").getString("referrer"))
    }

    @Test
    fun `an oversized referrer without a token is left out of the match`() = runTest {
        val h = Harness(referrer = "utm_content=${"x".repeat(4000)}")
        h.sdk().matchInstall(h.context)
        assertFalse(h.transport.body("installs/match").has("referrer"))
    }

    @Test
    fun `claim sends the install, app and raw referrer`() = runTest {
        val referrer = "utm_source=apps.facebook.com&utm_campaign=fb4a&utm_content=%7B%22source%22%3A%7B%22data%22%3A%22ab12%22%2C%22nonce%22%3A%22cd34%22%7D%7D"
        val h = Harness(referrer = referrer)
        val sdk = h.sdk()

        assertEquals(ReferrerClaimResult.Status.SUBMITTED, sdk.submitReferrerClaim(APP_ID)!!.status)

        val request = h.transport.requests.single()
        assertEquals("https://go.example.com/v1/claims/referrer", request.url)
        assertEquals(headers, request.headers)
        val body = JSONObject(request.body)
        assertEquals(setOf("installId", "appId", "referrer", "consent"), body.fields())
        assertEquals(sdk.installId(), body.getString("installId"))
        assertEquals(APP_ID, body.getString("appId"))
        assertEquals(referrer, body.getString("referrer"))
        assertEquals(true, body.get("consent"))
    }

    @Test
    fun `attest requests a challenge, binds the token to it and exchanges it`() = runTest {
        val provider = FakeProvider()
        val h = Harness(provider)
        // An install ID from an earlier launch, so the nonce can be checked against a fixed vector.
        h.preferences.edit().putString("installId:$SCOPE", "3f2b8c1e-5d4a-4e6f-9a7b-0c1d2e3f4a5b").commit()
        h.transport.on("attest/challenge") { ok(CHALLENGE) }.on("attest/play") { ok(ISSUED) }

        val result = h.sdk().attest(APP_ID)!!

        assertEquals(AttestationResult.Status.ATTESTED, result.status)
        assertEquals(listOf("attest/challenge", "attest/play"), h.transport.paths())
        h.transport.requests.forEach { assertEquals(headers, it.headers) }
        val challenge = h.transport.body("attest/challenge")
        assertEquals(setOf("appId"), challenge.fields())
        assertEquals(APP_ID, challenge.getString("appId"))
        // Computed outside this code base: printf '%s.%s' <challenge> <installId> | openssl dgst -sha256 -binary | base64url
        assertEquals(listOf("429fRq2FfDnzOAg9lUfZFLh83YvzHwYeRoxSHnXHE5I"), provider.nonces)
        val exchange = h.transport.body("attest/play")
        assertEquals(setOf("appId", "challengeId", "installId", "token"), exchange.fields())
        assertEquals(APP_ID, exchange.getString("appId"))
        assertEquals("chl_1", exchange.getString("challengeId"))
        assertEquals("3f2b8c1e-5d4a-4e6f-9a7b-0c1d2e3f4a5b", exchange.getString("installId"))
        assertEquals("play-integrity-token-0001", exchange.getString("token"))
    }

    @Test
    fun `track attaches the click token and the attestation once they exist`() = runTest {
        val h = Harness(FakeProvider(), REFERRER)
        h.transport.on("installs/match") { ok(MATCHED) }
            .on("attest/challenge") { ok(CHALLENGE) }.on("attest/play") { ok(ISSUED) }
        val sdk = h.sdk()
        sdk.matchInstall(h.context)
        sdk.attest(APP_ID)

        sdk.track("OPEN")

        val body = h.transport.body("track")
        assertEquals("tok.matched", body.getString("clickToken"))
        assertEquals("att.signed", body.getString("attestation"))
        assertEquals(sdk.installId(), body.getString("installId"))
    }

    @Test
    fun `a whole first launch is six requests under one install id`() = runTest {
        val h = Harness(FakeProvider(), REFERRER)
        h.transport.on("installs/match") { ok(MATCHED) }.on("claims/referrer") { RECORDED }
            .on("attest/challenge") { ok(CHALLENGE) }.on("attest/play") { ok(ISSUED) }
        val sdk = h.sdk()

        sdk.install(h.context)
        sdk.submitReferrerClaim(APP_ID)
        sdk.attest(APP_ID)
        sdk.track("OPEN")

        assertEquals(listOf("installs/match", "track", "claims/referrer", "attest/challenge", "attest/play", "track"), h.transport.paths())
        val ids = h.transport.requests.map { JSONObject(it.body) }.filter { it.has("installId") }.map { it.getString("installId") }
        assertEquals(5, ids.size)
        assertEquals(setOf(sdk.installId()), ids.toSet())
        val (installed, opened) = h.transport.bodies("track")
        assertEquals("INSTALL", installed.getString("type"))
        assertFalse(installed.has("attestation"))
        assertEquals("tok.matched", opened.getString("clickToken"))
        assertEquals("att.signed", opened.getString("attestation"))
        assertEquals(1, h.referrerReads)
    }

    @Test
    fun `a trailing slash on the endpoint does not double up`() = runTest {
        val h = Harness()
        val sdk = LinkRunway(h.context, "$ENDPOINT/", KEY, transport = h.transport).apply { setConsent(true) }
        sdk.track("OPEN")
        assertEquals("https://go.example.com/v1/track", h.transport.requests.single().url)
    }
}
