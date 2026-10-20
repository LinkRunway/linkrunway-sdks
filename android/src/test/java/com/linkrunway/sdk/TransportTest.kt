package com.linkrunway.sdk

import com.linkrunway.sdk.LoopbackServer.Reply
import kotlinx.coroutines.test.runTest
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import java.io.IOException

/**
 * The default transport against an HTTP server on this machine's loopback interface: what really
 * goes over a socket. No request leaves the machine.
 */
@RunWith(RobolectricTestRunner::class)
class TransportTest {
    private val server = LoopbackServer()
    private val context get() = RuntimeEnvironment.getApplication()

    @After
    fun stop() = server.close()

    private fun sdk(endpoint: String = "http://localhost:${server.port}") =
        LinkRunway(context, endpoint, KEY, null, UrlConnectionTransport(), { REFERRER }) { NOW }
            .apply { setConsent(true) }

    @Test
    fun `a request reaches the server as an authenticated JSON POST from the SDK user agent`() = runTest {
        server.respond = { Reply(200, """{"id":"evt_1","attributed":true,"duplicate":false}""", mapOf("Content-Type" to "application/json")) }
        val sdk = sdk()

        val result = sdk.track("OPEN", "event-ü-1")

        assertEquals(true, result!!.getBoolean("attributed"))
        val request = server.seen.single()
        assertEquals("POST", request.method)
        assertEquals("/v1/track", request.path)
        assertEquals("LinkRunwaySDK/0.2.0 Android", request.headers["user-agent"])
        assertEquals("Bearer $KEY", request.headers["authorization"])
        assertEquals("application/json", request.headers["content-type"])
        val body = JSONObject(request.body)
        assertEquals("event-ü-1", body.getString("eventId"))
        assertEquals(sdk.installId(), body.getString("installId"))
    }

    @Test
    fun `the first launch calls reach their endpoints`() = runTest {
        server.respond = { request -> Reply(200, if (request.path == "/v1/installs/match") MATCHED else "{}") }
        val sdk = sdk()

        sdk.install(context)
        sdk.submitReferrerClaim(APP_ID)

        assertEquals(listOf("/v1/installs/match", "/v1/track", "/v1/claims/referrer"), server.seen.map { it.path })
        assertEquals("tok.matched", JSONObject(server.seen[1].body).getString("clickToken"))
        assertEquals(REFERRER, JSONObject(server.seen[2].body).getString("referrer"))
    }

    @Test
    fun `an error status is read from the error body and a redirect is not followed`() = runTest {
        server.respond = { Reply(400, """{"message":"Invalid event"}""") }
        val invalid = failure<LinkRunwayException> { sdk().track("OPEN") }
        assertEquals(400, invalid.status)
        assertEquals("Invalid event", invalid.message)

        server.seen.clear()
        server.respond = { Reply(302, "", mapOf("Location" to "/v1/elsewhere")) }
        assertEquals(302, failure<LinkRunwayException> { sdk().track("OPEN") }.status)
        assertEquals(listOf("/v1/track"), server.seen.map { it.path })
    }

    @Test
    fun `a server error is retried over the socket and an unreachable server is an IOException`() = runTest {
        var calls = 0
        server.respond = { if (++calls < 3) Reply(503) else Reply(200) }
        assertTrue(sdk().track("OPEN") != null)
        assertEquals(3, server.seen.size)

        // Nothing listens on privileged port 1. A port this test had just closed could be bound
        // again before the SDK connected, and in CI the request to it once succeeded.
        failure<IOException> { sdk("http://localhost:1").track("OPEN") }
        assertEquals(3, server.seen.size)
    }
}
