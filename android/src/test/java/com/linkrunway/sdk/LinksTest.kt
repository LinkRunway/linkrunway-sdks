package com.linkrunway.sdk

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.util.UUID

/** Link opens, shares and referral codes: the calls that existed before, and how they treat the click token. */
@RunWith(RobolectricTestRunner::class)
class LinksTest {
    private val resolved = """{"clickId":"clk_2","clickToken":"tok.opened","path":"/a","url":"https://example.com/a","metadata":{}}"""

    @Test
    fun `earlier calls keep their wire format`() = runTest {
        val h = Harness()
        h.transport.on("resolve") { ok(resolved) }
            .on("shares") { ok("""{"shareId":"shr_1","url":"https://go.example.com/l/abc?s=shr_1"}""") }
            .on("deferred") { ok("""{"code":"ABCDEFGHJKLM","expiresAt":"2027-01-16T08:00:00.000Z"}""") }
            .on("deferred/claim") { ok("""{"clickId":"clk_3","clickToken":"tok.claimed","path":"/b","url":"https://example.com/b","metadata":{}}""") }
        val sdk = h.sdk()
        val claimId = UUID.fromString("7a1c2a52-4f0c-4b2e-9b51-4f2f5f0c1d11")

        assertEquals("/a", sdk.open("https://go.example.com/l/abc")!!.getString("path"))
        assertEquals("tok.opened", sdk.attributionToken())
        assertEquals("shr_1", sdk.createShare("lnk_1", "user-9").getString("shareId"))
        assertEquals("ABCDEFGHJKLM", sdk.createReferralCode()!!.getString("code"))
        sdk.claimReferralCode("ABCDEFGHJKLM", claimId)
        assertEquals("tok.claimed", sdk.attributionToken())
        assertNull(sdk.open("https://go.example.com/l/abc?lr_token=tok.direct"))
        assertEquals("tok.direct", sdk.attributionToken())

        assertEquals(listOf("resolve", "shares", "deferred", "deferred/claim"), h.transport.paths())
        assertEquals("""{"url":"https://go.example.com/l/abc","consent":true,"platform":"android"}""", h.transport.body("resolve").toString().replace("\\/", "/"))
        assertEquals("""{"linkId":"lnk_1","externalUserId":"user-9","channel":"native_share"}""", h.transport.body("shares").toString())
        assertEquals("""{"clickToken":"tok.opened","consent":true}""", h.transport.body("deferred").toString())
        assertEquals("""{"code":"ABCDEFGHJKLM","claimId":"$claimId","consent":true}""", h.transport.body("deferred/claim").toString())
    }

    @Test
    fun `an untracked open leaves the current attribution as it was`() = runTest {
        val h = Harness()
        val sdk = h.sdk()
        sdk.captureReferrer(REFERRER)
        // Over the plan's click allowance the server still routes the link but records no click.
        h.transport.on("resolve") { ok("""{"clickId":"","path":"/a","url":"https://example.com/a","metadata":{},"untracked":true}""") }

        assertEquals("/a", sdk.open("https://go.example.com/l/abc")!!.getString("path"))

        assertEquals("tok.referrer", sdk.attributionToken())
    }

    @Test
    fun `an open that recorded a click without a token replaces the earlier attribution`() = runTest {
        val h = Harness()
        val sdk = h.sdk()
        sdk.captureReferrer(REFERRER)
        // A click the server will not attribute (a privacy signal, a fraud rule) carries no token.
        h.transport.on("resolve") { ok("""{"clickId":"clk_3","path":"/a","url":"https://example.com/a","metadata":{}}""") }

        sdk.open("https://go.example.com/l/abc")

        assertNull(sdk.attributionToken())
        assertNull(h.stored("token"))
    }

    @Test
    fun `a token the server could never accept is not taken from a link or a referrer`() = runTest {
        val h = Harness()
        val sdk = h.sdk()
        val oversized = "t".repeat(1501)

        sdk.captureReferrer("lr_token=$oversized")
        sdk.captureReferrer("lr_token=")
        sdk.captureReferrer("utm_source=google-play&utm_medium=organic")
        assertNull(sdk.open("https://go.example.com/l/abc?lr_token=$oversized"))

        assertNull(sdk.attributionToken())
        assertTrue(h.transport.requests.isEmpty())

        sdk.captureReferrer("utm_source=x&lr_token=${"t".repeat(1500)}")
        assertEquals(1500, sdk.attributionToken()!!.length)
    }
}
