package com.linkrunway.sdk

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** The INSTALL event: built on the first-launch match, reported once, never held up by it. */
@RunWith(RobolectricTestRunner::class)
class InstallTest {
    private val unmatched = InstallMatchResult(false, MatchMethod.NONE, cached = true)

    @Test
    @Config(sdk = [23, 34])
    fun `install resolves the match first and reports INSTALL once with the matched token`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { ok(MATCHED) }
            .on("track") { ok("""{"id":"evt_1","attributed":true,"duplicate":false}""") }
        val sdk = h.sdk()

        val result = sdk.install(h.context)

        assertEquals(true, result!!.getBoolean("attributed"))
        assertEquals(listOf("installs/match", "track"), h.transport.paths())
        val event = h.transport.body("track")
        assertEquals("INSTALL", event.getString("type"))
        assertEquals("tok.matched", event.getString("clickToken"))
        assertEquals(h.transport.body("installs/match").getString("installId"), event.getString("installId"))
        assertTrue(UUID_V4.matches(event.getString("eventId")))

        assertNull(sdk.install(h.context))
        assertNull(h.sdk().install(h.context))
        assertEquals(2, h.transport.requests.size)
        // Once delivered, only the marker remains: the event ID has no further use.
        assertEquals(true, h.stored("install:token", ":sent"))
        assertNull(h.stored("install:token"))
    }

    @Test
    fun `install reuses a match that was already resolved`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { ok(MATCHED) }
        val sdk = h.sdk()

        sdk.matchInstall(h.context)
        sdk.install(h.context)

        assertEquals(listOf("installs/match", "track"), h.transport.paths())
        assertEquals("tok.matched", h.transport.body("track").getString("clickToken"))
    }

    @Test
    fun `an unmatched install is reported without a click token`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { ok("""{"matched":false,"method":"NONE"}""") }

        h.sdk().install(h.context)

        // The server refused the referrer's click, so its token is not sent with the event either.
        assertFalse(h.transport.body("track").has("clickToken"))
    }

    @Test
    fun `a failed match request does not stop INSTALL and falls back to the referrer token`() = runTest {
        for (status in listOf(404, 500)) {
            val h = Harness(referrer = REFERRER)
            h.preferences.edit().clear().commit()
            h.transport.on("installs/match") { HttpResponse(status, """{"message":"Unavailable"}""") }
            val sdk = h.sdk()

            val result = sdk.install(h.context)

            assertTrue(result != null)
            val event = h.transport.body("track")
            assertEquals("INSTALL", event.getString("type"))
            assertEquals("tok.referrer", event.getString("clickToken"))
            assertTrue(h.preferences.all.keys.none { it.startsWith("match:") })
            // INSTALL is delivered, so the first launch is over and the server is not asked again.
            val asked = h.transport.requests.size
            assertEquals(unmatched, sdk.matchInstall(h.context))
            assertEquals(asked, h.transport.requests.size)
        }
    }

    @Test
    fun `an unreachable server fails the install, which then runs whole on the next launch`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { throw java.io.IOException("offline") }.on("track") { throw java.io.IOException("offline") }

        failure<java.io.IOException> { h.sdk().install(h.context) }
        assertNull(h.stored("install:token", ":sent"))

        h.transport.on("installs/match") { ok(MATCHED) }.on("track") { ok() }
        h.sdk().install(h.context)

        val events = h.transport.bodies("track")
        assertEquals(1, events.map { it.getString("eventId") }.toSet().size)
        assertEquals("tok.matched", events.last().getString("clickToken"))
        assertEquals(true, h.stored("install:token", ":sent"))
    }

    @Test
    fun `a failed INSTALL is retried with the same event id and the stored match`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { ok(MATCHED) }.on("track") { HttpResponse(503, "{}") }
        val sdk = h.sdk()

        assertEquals(503, failure<LinkRunwayException> { sdk.install(h.context) }.status)
        assertNull(h.stored("install:token", ":sent"))

        h.transport.on("track") { ok("""{"id":"evt_1","attributed":true,"duplicate":false}""") }
        h.sdk().install(h.context)

        val events = h.transport.bodies("track")
        assertEquals(4, events.size)
        assertEquals(1, events.map { it.getString("eventId") }.toSet().size)
        assertEquals(1, h.transport.bodies("installs/match").size)
        assertEquals("tok.matched", events.last().getString("clickToken"))
    }

    @Test
    fun `an install reported by an earlier SDK version is neither re-sent nor re-matched`() = runTest {
        val h = Harness(referrer = REFERRER)
        // The storage an app on the previous SDK version already has.
        h.preferences.edit().putString("token:$SCOPE", "tok.legacy")
            .putString("install:token:$SCOPE", "9b2f6c0e-1a2b-4c3d-8e4f-5a6b7c8d9e0f")
            .putBoolean("install:token:$SCOPE:sent", true).commit()
        val sdk = h.sdk()

        assertNull(sdk.install(h.context))
        assertEquals(unmatched, sdk.matchInstall(h.context))

        assertEquals("tok.legacy", sdk.attributionToken())
        assertTrue(h.transport.requests.isEmpty())
        assertEquals(0, h.referrerReads)
    }

    @Test
    fun `an unsent install from an earlier SDK version keeps its event id`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.preferences.edit().putString("install:token:$SCOPE", "9b2f6c0e-1a2b-4c3d-8e4f-5a6b7c8d9e0f").commit()

        h.sdk().install(h.context)

        assertEquals("9b2f6c0e-1a2b-4c3d-8e4f-5a6b7c8d9e0f", h.transport.body("track").getString("eventId"))
    }

    @Test
    fun `an install whose match was erased by a withdrawal is still reported, unmatched`() = runTest {
        val h = Harness(referrer = REFERRER)
        h.transport.on("installs/match") { ok(MATCHED) }
        val sdk = h.sdk()
        sdk.matchInstall(h.context)
        sdk.setConsent(false)
        sdk.setConsent(true)

        sdk.install(h.context)

        assertEquals(listOf("installs/match", "track"), h.transport.paths())
        val event = h.transport.body("track")
        assertEquals("INSTALL", event.getString("type"))
        assertFalse(event.has("clickToken"))
        assertFalse(event.getString("installId") == h.transport.body("installs/match").getString("installId"))
    }
}
