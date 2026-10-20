package com.linkrunway.sdk

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.UUID

/** Consent gates every path: nothing is sent, read or stored without it, and withdrawal erases. */
@RunWith(RobolectricTestRunner::class)
class ConsentTest {
    private fun Harness.serve() = apply {
        transport.on("installs/match") { ok(MATCHED) }
            .on("attest/challenge") { ok(CHALLENGE) }.on("attest/play") { ok(ISSUED) }
    }

    @Test
    fun `nothing is sent, read or stored without consent`() = runTest {
        val provider = FakeProvider()
        val h = Harness(provider, REFERRER).serve()
        val sdk = h.sdk(consent = false)

        assertNull(sdk.installId())
        assertNull(sdk.attributionToken())
        sdk.captureReferrer(REFERRER)
        assertNull(sdk.open("https://go.example.com/l/abc"))
        assertNull(sdk.open("https://go.example.com/l/abc?lr_token=tok.direct"))
        assertNull(sdk.track("OPEN"))
        assertNull(sdk.install(h.context))
        assertNull(sdk.matchInstall(h.context))
        assertNull(sdk.submitReferrerClaim(APP_ID))
        assertNull(sdk.attest(APP_ID))
        assertNull(sdk.claimReferralCode("ABCDEFGHJKLM", UUID.randomUUID()))
        assertEquals("Consent is required for tracked sharing", failure<IllegalStateException> { sdk.createShare("lnk_1") }.message)
        failure<IllegalStateException> { sdk.createReferralCode() }

        assertTrue(h.transport.requests.isEmpty())
        assertTrue(h.preferences.all.isEmpty())
        assertFalse(h.sentinel.exists())
        assertEquals(0, h.referrerReads)
        assertTrue(provider.nonces.isEmpty())
        assertNull(sdk.attributionToken())
    }

    @Test
    @Config(sdk = [23, 34])
    fun `withdrawal clears the install id, click token, match and attestation`() = runTest {
        val h = Harness(FakeProvider(), REFERRER).serve()
        val sdk = h.sdk()
        sdk.matchInstall(h.context)
        sdk.attest(APP_ID)
        val first = sdk.installId()!!
        assertEquals(first, h.stored("installId"))
        assertEquals("tok.matched", h.stored("token"))
        assertTrue((h.stored("match") as String).contains("clk_1"))
        assertTrue((h.stored("attestation") as String).contains("att.signed"))

        sdk.setConsent(false)

        // What is left identifies nothing: the marker that this install's first launch was resolved.
        assertEquals(mapOf("match:$SCOPE:resolved" to true), h.state)
        assertNull(sdk.installId())
        assertNull(sdk.attributionToken())
        assertNull(sdk.installMatch())
        assertNull(sdk.track("OPEN"))
        assertFalse(h.transport.paths().contains("track"))

        sdk.setConsent(true)
        sdk.track("OPEN")

        val body = h.transport.body("track")
        assertTrue(UUID_V4.matches(body.getString("installId")))
        assertNotEquals(first, body.getString("installId"))
        assertFalse(body.has("clickToken"))
        assertFalse(body.has("attestation"))
    }

    @Test
    fun `withdrawal is honoured by an instance created after it`() = runTest {
        val h = Harness(FakeProvider(), REFERRER).serve()
        h.sdk().apply { matchInstall(h.context); attest(APP_ID); setConsent(false) }

        val restarted = h.sdk()
        restarted.track("OPEN")

        assertNull(restarted.attributionToken())
        val body = h.transport.body("track")
        assertFalse(body.has("clickToken"))
        assertFalse(body.has("attestation"))
    }

    @Test
    fun `only the one-shot markers outlive withdrawal and nothing is reported twice`() = runTest {
        val h = Harness(referrer = REFERRER).serve()
        val sdk = h.sdk()
        sdk.install(h.context)
        assertEquals(ReferrerClaimResult.Status.SUBMITTED, sdk.submitReferrerClaim(APP_ID)!!.status)

        sdk.setConsent(false)

        val markers = mapOf("install:token:$SCOPE:sent" to true, "match:$SCOPE:resolved" to true, "claim:$SCOPE:sent" to true)
        assertEquals(markers, h.state)

        sdk.setConsent(true)
        val sent = h.transport.requests.size
        assertNull(sdk.install(h.context))
        assertEquals(ReferrerClaimResult.Status.ALREADY_SUBMITTED, sdk.submitReferrerClaim(APP_ID)!!.status)
        // The first launch is over: the erased match is not asked for again under a new identity.
        assertEquals(InstallMatchResult(false, MatchMethod.NONE, cached = true), sdk.matchInstall(h.context))
        assertEquals(sent, h.transport.requests.size)
        assertNull(sdk.attributionToken())
    }

    @Test
    fun `an answer that arrives after withdrawal is discarded`() = runTest {
        val h = Harness(FakeProvider(), REFERRER)
        lateinit var sdk: LinkRunway
        h.transport.on("installs/match") { sdk.setConsent(false); ok(MATCHED) }
        sdk = h.sdk()

        assertNull(sdk.matchInstall(h.context))
        assertTrue(h.state.isEmpty())

        h.transport.on("attest/challenge") { ok(CHALLENGE) }.on("attest/play") { sdk.setConsent(false); ok(ISSUED) }
        sdk.setConsent(true)
        assertNull(sdk.attest(APP_ID))
        assertTrue(h.state.isEmpty())

        h.transport.on("resolve") { sdk.setConsent(false); ok("""{"clickId":"clk_2","clickToken":"tok.opened"}""") }
        sdk.setConsent(true)
        assertNull(sdk.open("https://go.example.com/l/abc"))
        assertTrue(h.state.isEmpty())

        // A pending claim leaves its retry times behind; a withdrawal removes those as well.
        h.transport.on("claims/referrer") { PENDING }
        sdk.setConsent(true)
        assertEquals(ReferrerClaimResult.Status.PENDING, sdk.submitReferrerClaim(APP_ID)!!.status)
        assertEquals(setOf("installId:$SCOPE", "claim:$SCOPE:since", "claim:$SCOPE:retryAt"), h.state.keys)
        sdk.setConsent(false)
        assertTrue(h.state.isEmpty())
    }

    @Test
    fun `a call cut short by a withdrawal reports nothing`() = runTest {
        val h = Harness(FakeProvider(), REFERRER)
        lateinit var sdk: LinkRunway
        val withdraw: suspend (HttpRequest) -> HttpResponse = { sdk.setConsent(false); HttpResponse(503, "{}") }
        h.transport.on("claims/referrer", withdraw).on("attest/challenge", withdraw).on("installs/match", withdraw)
        sdk = h.sdk()

        assertNull(sdk.submitReferrerClaim(APP_ID))
        sdk.setConsent(true)
        assertNull(sdk.attest(APP_ID))
        sdk.setConsent(true)
        assertNull(sdk.install(h.context))

        assertEquals(listOf("claims/referrer", "attest/challenge", "installs/match"), h.transport.paths())
        assertTrue(h.state.isEmpty())
    }

    @Test
    fun `an answer for a withdrawn identity is not adopted by the next one`() = runTest {
        val h = Harness(FakeProvider(), REFERRER)
        lateinit var sdk: LinkRunway
        // Consent is withdrawn and granted again while the request is in flight.
        h.transport.on("installs/match") { sdk.setConsent(false); sdk.setConsent(true); ok(MATCHED) }
        sdk = h.sdk()

        assertNull(sdk.matchInstall(h.context))

        assertNull(sdk.attributionToken())
        assertNull(h.stored("match"))
    }

    @Test
    fun `withdrawal stops the retries of a request in flight`() = runTest {
        val h = Harness()
        lateinit var sdk: LinkRunway
        h.transport.on("track") { sdk.setConsent(false); HttpResponse(503, "{}") }
        sdk = h.sdk()

        val error = failure<IllegalStateException> { sdk.track("OPEN") }

        assertEquals("Consent was withdrawn", error.message)
        assertEquals(1, h.transport.requests.size)
    }

    @Test
    fun `granting consent again restores what is still stored`() = runTest {
        val h = Harness(FakeProvider(), REFERRER).serve()
        h.sdk().apply { matchInstall(h.context); attest(APP_ID) }
        val id = h.stored("installId")

        val restarted = h.sdk(consent = false)
        assertNull(restarted.attributionToken())
        restarted.setConsent(true)
        restarted.track("OPEN")

        assertEquals("tok.matched", restarted.attributionToken())
        val body = h.transport.body("track")
        assertEquals(id, body.getString("installId"))
        assertEquals("att.signed", body.getString("attestation"))
    }
}
