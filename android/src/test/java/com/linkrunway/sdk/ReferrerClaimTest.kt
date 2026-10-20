package com.linkrunway.sdk

import com.linkrunway.sdk.ReferrerClaimResult.Status
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.delay
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.IOException

/** Referrer claims: one final answer per install, and never able to break the install flow. */
@RunWith(RobolectricTestRunner::class)
class ReferrerClaimTest {
    private val google = "utm_source=google&utm_medium=cpc&gclid=EAIaIQobChMI0abc"
    private val submitted = ReferrerClaimResult(Status.SUBMITTED, mapOf("META" to "NO_KEY", "GOOGLE_ADS" to "RECORDED"))
    private val alreadySubmitted = ReferrerClaimResult(Status.ALREADY_SUBMITTED)
    private val pending = ReferrerClaimResult(Status.PENDING, mapOf("GOOGLE_ADS" to "PENDING"))

    @Test
    @Config(sdk = [23, 34])
    fun `the claim is delivered once per install`() = runTest {
        val h = Harness(referrer = google)
        h.transport.on("claims/referrer") { RECORDED }
        val sdk = h.sdk()

        assertEquals(submitted, sdk.submitReferrerClaim(APP_ID))
        assertEquals(alreadySubmitted, sdk.submitReferrerClaim(APP_ID))
        assertEquals(alreadySubmitted, h.sdk().submitReferrerClaim(APP_ID))

        assertEquals(listOf("claims/referrer"), h.transport.paths())
        assertEquals(google, h.transport.body("claims/referrer").getString("referrer"))
        assertEquals(1, h.referrerReads)
        assertEquals(true, h.stored("claim", ":sent"))
    }

    @Test
    fun `concurrent claims share one request`() = runTest {
        val h = Harness(referrer = google)
        h.transport.on("claims/referrer") { delay(50); RECORDED }
        val sdk = h.sdk()

        val results = List(3) { async { sdk.submitReferrerClaim(APP_ID) } }.awaitAll()

        assertEquals(listOf(submitted, alreadySubmitted, alreadySubmitted), results)
        assertEquals(1, h.transport.requests.size)
    }

    @Test
    @Config(sdk = [23, 34])
    fun `a pending claim is sent again after the pause the server asked for`() = runTest {
        val h = Harness(referrer = google)
        h.transport.on("claims/referrer") { PENDING }
        val sdk = h.sdk()

        assertEquals(pending, sdk.submitReferrerClaim(APP_ID))
        // Inside the hour the server asked for, nothing is sent, in this process or the next.
        h.clock = NOW + HOUR - 1
        assertEquals(Status.PENDING, sdk.submitReferrerClaim(APP_ID)!!.status)
        assertEquals(Status.PENDING, h.sdk().submitReferrerClaim(APP_ID)!!.status)
        assertEquals(1, h.transport.requests.size)
        assertNull(h.stored("claim", ":sent"))

        h.clock = NOW + HOUR
        assertEquals(pending, h.sdk().submitReferrerClaim(APP_ID))
        assertEquals(2, h.transport.requests.size)

        h.clock = NOW + 2 * HOUR
        h.transport.on("claims/referrer") { RECORDED }
        assertEquals(submitted, h.sdk().submitReferrerClaim(APP_ID))
        assertEquals(alreadySubmitted, h.sdk().submitReferrerClaim(APP_ID))
        assertEquals(3, h.transport.requests.size)
        // Every attempt carried the same install and referrer.
        assertEquals(1, h.transport.bodies("claims/referrer").map { it.toString() }.toSet().size)
        assertEquals(setOf("installId:$SCOPE", "claim:$SCOPE:sent"), h.state.keys)
    }

    @Test
    fun `a claim that stays pending is given up after two days`() = runTest {
        val h = Harness(referrer = google)
        h.transport.on("claims/referrer") { HttpResponse(202, """{"claims":[],"pending":true}""") }

        for (hour in 0..47) {
            h.clock = NOW + hour * HOUR
            assertEquals(Status.PENDING, h.sdk().submitReferrerClaim(APP_ID)!!.status)
        }
        assertEquals(48, h.transport.requests.size)

        // The 49th answer arrives two days after the first: it is the last one asked for.
        h.clock = NOW + 48 * HOUR
        assertEquals(Status.PENDING, h.sdk().submitReferrerClaim(APP_ID)!!.status)
        h.clock = NOW + 72 * HOUR
        assertEquals(alreadySubmitted, h.sdk().submitReferrerClaim(APP_ID))
        assertEquals(49, h.transport.requests.size)
    }

    @Test
    fun `the pause is bounded whatever the server or the clock says`() = runTest {
        val h = Harness(referrer = google)
        h.transport.on("claims/referrer") { HttpResponse(202, """{"pending":true,"retryAfterSeconds":999999999}""") }
        assertEquals(Status.PENDING, h.sdk().submitReferrerClaim(APP_ID)!!.status)

        // A day is the longest pause; a status of 202 alone also means pending.
        h.clock = NOW + 24 * HOUR
        h.transport.on("claims/referrer") { HttpResponse(202, """{"retryAfterSeconds":0}""") }
        assertEquals(Status.PENDING, h.sdk().submitReferrerClaim(APP_ID)!!.status)
        assertEquals(2, h.transport.requests.size)

        // A minute is the shortest; and a clock set back by months does not freeze the claim.
        h.clock = NOW + 24 * HOUR + 60_000
        assertEquals(Status.PENDING, h.sdk().submitReferrerClaim(APP_ID)!!.status)
        h.clock = NOW - 2000 * HOUR
        h.transport.on("claims/referrer") { RECORDED }
        assertEquals(submitted, h.sdk().submitReferrerClaim(APP_ID))
        assertEquals(4, h.transport.requests.size)
    }

    @Test
    fun `nothing is sent when Play has no referrer`() = runTest {
        for (referrer in listOf(null, "", "   ")) {
            val h = Harness(referrer = referrer)
            assertEquals(ReferrerClaimResult(Status.NO_REFERRER), h.sdk().submitReferrerClaim(APP_ID))
            assertTrue(h.transport.requests.isEmpty())
            assertTrue(h.state.isEmpty())
        }
    }

    @Test
    fun `a failed claim is reported, never thrown, and is tried again later`() = runTest {
        val h = Harness(referrer = google)
        h.transport.on("claims/referrer") { HttpResponse(500, """{"message":"Unavailable"}""") }
        val sdk = h.sdk()

        val failed = sdk.submitReferrerClaim(APP_ID)!!

        assertEquals(Status.FAILED, failed.status)
        assertEquals(500, (failed.error as LinkRunwayException).status)
        assertEquals(3, h.transport.requests.size)
        assertNull(h.stored("claim", ":sent"))

        h.transport.on("claims/referrer") { throw IOException("offline") }
        assertTrue(sdk.submitReferrerClaim(APP_ID)!!.error is IOException)

        h.transport.on("claims/referrer") { RECORDED }
        assertEquals(submitted, h.sdk().submitReferrerClaim(APP_ID))
    }

    @Test
    fun `a failing claim before or after install never stops the INSTALL event`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { ok(MATCHED) }
            .on("claims/referrer") { HttpResponse(404, """{"message":"App not found"}""") }
        val sdk = h.sdk()

        assertEquals(Status.FAILED, sdk.submitReferrerClaim(APP_ID)!!.status)
        val result = sdk.install(h.context)
        assertEquals(Status.FAILED, sdk.submitReferrerClaim(APP_ID)!!.status)

        assertTrue(result != null)
        assertEquals("INSTALL", h.transport.body("track").getString("type"))
        assertEquals(true, h.stored("install:token", ":sent"))
        // Play was read once for the claim, the match and the second claim of this launch.
        assertEquals(1, h.referrerReads)
    }

    @Test
    fun `an unreadable referrer or an unusable argument is a failed claim, not an exception`() = runTest {
        val unreadable = Harness(referrer = google)
        unreadable.referrerError = IllegalStateException("Install Referrer unavailable: 1")
        val error = unreadable.sdk().submitReferrerClaim(APP_ID)!!
        assertEquals(Status.FAILED, error.status)
        assertEquals("Install Referrer unavailable: 1", error.error!!.message)

        val h = Harness(referrer = google)
        for (appId in listOf("", "  ", "a".repeat(101))) {
            val result = h.sdk().submitReferrerClaim(appId)!!
            assertEquals(Status.FAILED, result.status)
            assertTrue(result.error is IllegalArgumentException)
        }

        val oversized = Harness(referrer = "utm_content=${"x".repeat(8000)}")
        assertEquals(Status.FAILED, oversized.sdk().submitReferrerClaim(APP_ID)!!.status)

        assertTrue(h.transport.requests.isEmpty() && unreadable.transport.requests.isEmpty() && oversized.transport.requests.isEmpty())
    }

    @Test
    fun `the longest referrer the server accepts is sent whole`() = runTest {
        val referrer = "gclid=${"x".repeat(7994)}"
        val h = Harness(referrer = referrer)

        assertEquals(Status.SUBMITTED, h.sdk().submitReferrerClaim(APP_ID)!!.status)

        assertEquals(8000, h.transport.body("claims/referrer").getString("referrer").length)
    }
}
