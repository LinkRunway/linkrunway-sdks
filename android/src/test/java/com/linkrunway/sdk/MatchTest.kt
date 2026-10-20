package com.linkrunway.sdk

import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** First-launch matching: the server is asked once per install and the answer is kept. */
@RunWith(RobolectricTestRunner::class)
class MatchTest {
    private val unmatched = InstallMatchResult(false, MatchMethod.NONE, cached = true)

    @Test
    @Config(sdk = [23, 34])
    fun `the match is asked once and then answered from storage`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { ok(MATCHED) }
        val sdk = h.sdk()
        assertNull(sdk.installMatch())

        val first = sdk.matchInstall(h.context)!!

        val metadata = mapOf("campaign" to "spring", "rank" to 3, "vip" to true, "note" to null)
        assertEquals(InstallMatchResult(true, MatchMethod.REFERRER, "clk_1", "/promo", "https://example.com/promo", metadata), first)
        assertEquals("tok.matched", sdk.attributionToken())
        // The token lives in its own slot; the stored outcome does not repeat it.
        assertFalse((h.stored("match") as String).contains("tok.matched"))

        val again = sdk.matchInstall(h.context)!!
        val restarted = h.sdk()

        assertEquals(first.copy(cached = true), again)
        assertEquals(first.copy(cached = true), restarted.matchInstall(h.context))
        assertEquals(first.copy(cached = true), restarted.installMatch())
        assertEquals(listOf("installs/match"), h.transport.paths())
        assertEquals(1, h.referrerReads)
    }

    @Test
    fun `concurrent first launches share one request`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { delay(50); ok(MATCHED) }
        val sdk = h.sdk()

        val results = List(3) { async { sdk.matchInstall(h.context)!! } }.awaitAll()

        assertEquals(1, h.transport.requests.size)
        assertEquals(listOf(false, true, true), results.map { it.cached })
    }

    @Test
    fun `an unmatched answer is stored too and does not adopt the referrer token`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { ok("""{"matched":false,"method":"NONE"}""") }
        val sdk = h.sdk()

        assertEquals(unmatched.copy(cached = false), sdk.matchInstall(h.context))
        assertEquals(unmatched, sdk.matchInstall(h.context))

        assertNull(sdk.attributionToken())
        assertEquals(1, h.transport.requests.size)
    }

    @Test
    fun `a method this SDK does not know is still a stored answer`() = runTest {
        val h = Harness()
        h.transport.on("installs/match") { ok("""{"matched":true,"method":"HOUSEHOLD","clickId":"clk_9","clickToken":"tok.new"}""") }

        val result = h.sdk().matchInstall(h.context)!!

        assertEquals(InstallMatchResult(true, MatchMethod.UNKNOWN, "clk_9"), result)
        assertEquals(result.copy(cached = true), h.sdk().installMatch())
        assertEquals("tok.new", h.stored("token"))
    }

    @Test
    fun `a link opened before the match keeps its token`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { ok(MATCHED) }
        val sdk = h.sdk()
        sdk.open("https://go.example.com/l/abc?lr_token=tok.latest")

        assertTrue(sdk.matchInstall(h.context)!!.matched)

        // The link is the more recent touch, so the install's own click does not replace it.
        assertEquals("tok.latest", sdk.attributionToken())
    }

    @Test
    fun `a failed request is reported and the next call asks again`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { HttpResponse(500, """{"message":"Unavailable"}""") }
        val sdk = h.sdk()

        val error = failure<LinkRunwayException> { sdk.matchInstall(h.context) }

        assertEquals(500, error.status)
        assertTrue(h.preferences.all.keys.none { it.startsWith("match:") })
        assertNull(sdk.attributionToken())
        assertNull(sdk.installMatch())

        h.transport.on("installs/match") { ok(MATCHED) }
        assertEquals(false, sdk.matchInstall(h.context)!!.cached)
        assertEquals("tok.matched", sdk.attributionToken())
        // Three attempts for the failure, one for the success; Play was read once for both.
        assertEquals(4, h.transport.requests.size)
        assertEquals(1, h.referrerReads)
    }

    @Test
    fun `an unreadable Play referrer fails the call before anything is asked`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.referrerError = IllegalStateException("Install Referrer unavailable: 1")
        h.transport.on("installs/match") { ok(MATCHED) }
        val sdk = h.sdk()

        assertEquals("Install Referrer unavailable: 1", failure<IllegalStateException> { sdk.matchInstall(h.context) }.message)
        failure<IllegalStateException> { sdk.install(h.context) }

        // Asking without the referrer would fix an unmatched answer for this install forever.
        assertTrue(h.transport.requests.isEmpty())
        assertNull(h.stored("install:token", ":sent"))

        h.referrerError = null
        sdk.install(h.context)
        assertEquals(listOf("installs/match", "track"), h.transport.paths())
        assertEquals(REFERRER, h.transport.body("installs/match").getString("referrer"))
    }

    @Test
    fun `a slow Play referrer times out instead of hanging the first launch`() = runTest {
        val h = Harness()
        val sdk = LinkRunway(h.context, ENDPOINT, KEY, null, h.transport, { delay(60_000); REFERRER }) { NOW }
        sdk.setConsent(true)

        assertEquals("Install Referrer timed out", failure<IllegalStateException> { sdk.matchInstall(h.context) }.message)

        assertTrue(h.transport.requests.isEmpty())
    }

    @Test
    fun `a match resolved before a consent withdrawal is not asked for again`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { ok(MATCHED) }
        val sdk = h.sdk()
        sdk.matchInstall(h.context)

        sdk.setConsent(false)
        assertNull(sdk.installMatch())
        assertNull(sdk.matchInstall(h.context))
        sdk.setConsent(true)

        // The erased answer reads as unmatched: the install is not matched again under a new identity.
        assertEquals(unmatched, sdk.matchInstall(h.context))
        assertEquals(unmatched, h.sdk().installMatch())
        assertNull(sdk.attributionToken())
        assertEquals(1, h.transport.requests.size)
    }

    @Test
    fun `without the Play Store the default reader finds no referrer and the match still runs`() = runTest {
        val h = Harness()
        val sdk = LinkRunway(h.context, ENDPOINT, KEY, transport = h.transport).apply { setConsent(true) }

        sdk.install(h.context)

        assertEquals(listOf("installs/match", "track"), h.transport.paths())
        assertFalse(h.transport.body("installs/match").has("referrer"))
        assertEquals(ReferrerClaimResult.Status.NO_REFERRER, sdk.submitReferrerClaim(APP_ID)!!.status)
    }
}
