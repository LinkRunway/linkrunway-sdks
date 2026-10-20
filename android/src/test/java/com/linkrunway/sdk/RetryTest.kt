package com.linkrunway.sdk

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.currentTime
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import java.io.IOException
import java.net.SocketTimeoutException

/** Transient failures get three attempts with a 300 ms then 600 ms pause; everything else fails at once. */
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(RobolectricTestRunner::class)
class RetryTest {
    /** Answers the track endpoint from a script of statuses (an Int) and transport failures (an exception). */
    private fun Harness.script(vararg steps: Any) = apply {
        val remaining = ArrayDeque(steps.toList())
        transport.on("track") {
            when (val step = remaining.removeFirst()) {
                is Exception -> throw step
                200 -> ok("""{"id":"evt_1","attributed":false,"duplicate":false}""")
                else -> HttpResponse(step as Int, """{"message":"Status $step"}""")
            }
        }
    }

    @Test
    fun `429 and 5xx are retried with backoff until the request succeeds`() = runTest {
        val h = Harness().script(429, 503, 200)

        val result = h.sdk().track("OPEN", "event-1")

        assertEquals("evt_1", result!!.getString("id"))
        assertEquals(3, h.transport.requests.size)
        assertEquals(900L, currentTime)
        // Every attempt is the same request, so the server deduplicates on the event ID.
        assertEquals(1, h.transport.requests.map { it.body }.toSet().size)
    }

    @Test
    fun `a single retry waits 300 ms`() = runTest {
        val h = Harness().script(500, 200)

        h.sdk().track("OPEN")

        assertEquals(2, h.transport.requests.size)
        assertEquals(300L, currentTime)
    }

    @Test
    fun `the third failure is reported with its status and message`() = runTest {
        for (status in listOf(429, 500, 503)) {
            val h = Harness().script(status, status, status)

            val error = failure<LinkRunwayException> { h.sdk().track("OPEN") }

            assertEquals(status, error.status)
            assertEquals("Status $status", error.message)
            assertEquals(3, h.transport.requests.size)
        }
    }

    @Test
    fun `transport failures are retried and the last one is thrown`() = runTest {
        val recovered = Harness().script(IOException("reset"), SocketTimeoutException("slow"), 200)
        assertEquals("evt_1", recovered.sdk().track("OPEN")!!.getString("id"))
        assertEquals(3, recovered.transport.requests.size)

        val offline = Harness().script(IOException("one"), IOException("two"), IOException("three"))
        assertEquals("three", failure<IOException> { offline.sdk().track("OPEN") }.message)
        assertEquals(3, offline.transport.requests.size)
    }

    @Test
    fun `client errors are not retried`() = runTest {
        for (status in listOf(400, 401, 403, 404, 409)) {
            val h = Harness().script(status)

            val error = failure<LinkRunwayException> { h.sdk().track("OPEN") }

            assertEquals(status, error.status)
            assertEquals(1, h.transport.requests.size)
        }
        assertEquals(0L, currentTime)
    }

    @Test
    fun `redirects are errors, not followed`() = runTest {
        val h = Harness().script(302)
        assertEquals(302, failure<LinkRunwayException> { h.sdk().track("OPEN") }.status)
        assertEquals(1, h.transport.requests.size)
    }

    @Test
    fun `unreadable bodies do not escape as parser errors`() = runTest {
        val h = Harness()
        h.transport.on("track") { HttpResponse(502, "<html>Bad gateway</html>") }
        val gateway = failure<LinkRunwayException> { h.sdk().track("OPEN") }
        assertEquals(502, gateway.status)
        assertEquals("Request failed", gateway.message)

        h.transport.on("track") { HttpResponse(200, "<html>captive portal</html>") }
        assertEquals("Malformed response", failure<LinkRunwayException> { h.sdk().track("OPEN") }.message)

        h.transport.on("track") { HttpResponse(204, "") }
        assertEquals(0, h.sdk().track("OPEN")!!.length())
    }

    @Test
    fun `the new calls retry the same way`() = runTest {
        val h = Harness(FakeProvider(), REFERRER)
        var attempts = 0
        val flaky: suspend (HttpRequest) -> HttpResponse = { request ->
            if (attempts++ % 2 == 0) HttpResponse(503, "{}") else when (request.url.substringAfter("/v1/")) {
                "installs/match" -> ok(MATCHED)
                "attest/challenge" -> ok(CHALLENGE)
                else -> ok()
            }
        }
        val paths = listOf("installs/match", "claims/referrer", "attest/challenge")
        paths.forEach { h.transport.on(it, flaky) }
        h.transport.on("attest/play") { ok(ISSUED) }
        val sdk = h.sdk()

        assertTrue(sdk.matchInstall(h.context)!!.matched)
        assertEquals(ReferrerClaimResult.Status.SUBMITTED, sdk.submitReferrerClaim(APP_ID)!!.status)
        assertEquals(AttestationResult.Status.ATTESTED, sdk.attest(APP_ID)!!.status)

        assertEquals(paths.flatMap { listOf(it, it) } + "attest/play", h.transport.paths())
    }

    @Test
    fun `the attestation exchange is not repeated after a server error`() = runTest {
        // The server spends a challenge on its first look; asking again could only fail differently.
        val h = Harness(FakeProvider())
        h.transport.on("attest/challenge") { ok(CHALLENGE) }
            .on("attest/play") { HttpResponse(503, """{"message":"The Play Integrity quota for this app is exhausted"}""") }

        val refused = h.sdk().attest(APP_ID)!!

        assertEquals(503, (refused.error as LinkRunwayException).status)
        assertEquals("The Play Integrity quota for this app is exhausted", refused.error!!.message)
        assertEquals(listOf("attest/challenge", "attest/play"), h.transport.paths())
    }

    @Test
    fun `the attestation exchange is repeated when it was throttled or never arrived`() = runTest {
        val h = Harness(FakeProvider())
        val steps = ArrayDeque<Any>(listOf(429, IOException("reset"), 200))
        h.transport.on("attest/challenge") { ok(CHALLENGE) }.on("attest/play") {
            when (val step = steps.removeFirst()) {
                is Exception -> throw step
                200 -> ok(ISSUED)
                else -> HttpResponse(step as Int, "{}")
            }
        }

        assertEquals(AttestationResult.Status.ATTESTED, h.sdk().attest(APP_ID)!!.status)

        assertEquals(listOf("attest/challenge", "attest/play", "attest/play", "attest/play"), h.transport.paths())
        assertEquals(1, h.transport.bodies("attest/play").map { it.toString() }.toSet().size)
    }
}
