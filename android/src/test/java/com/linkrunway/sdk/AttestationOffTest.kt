package com.linkrunway.sdk

import com.linkrunway.sdk.AttestationResult.Status
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

/** An owner can turn attestation off for an app; the challenge endpoint then answers 409. */
@RunWith(RobolectricTestRunner::class)
class AttestationOffTest {
    private val off = AttestationResult(Status.OFF)
    private val conflict = HttpResponse(409, """{"message":"Attestation is off for this app"}""")

    @Test
    fun `a 409 turns attestation off quietly for the rest of the process`() = runTest {
        val provider = FakeProvider()
        val h = Harness(provider)
        h.transport.on("attest/challenge") { conflict }
        val sdk = h.sdk()

        // No error and no expiry: a setting, not a failure.
        assertEquals(off, sdk.attest(APP_ID))
        // Not retried, and not asked again in this process, even long after the refusal pause.
        h.clock = NOW + 6 * HOUR
        assertEquals(off, sdk.attest(APP_ID))
        assertEquals(listOf("attest/challenge"), h.transport.paths())
        assertTrue(provider.nonces.isEmpty())

        // Tracking goes on, unattested.
        assertTrue(sdk.track("OPEN") != null)
        assertFalse(h.transport.body("track").has("attestation"))
        assertNull(h.stored("attestation"))
    }

    @Test
    fun `another app, or the next process, asks again`() = runTest {
        val h = Harness(FakeProvider())
        h.transport.on("attest/challenge") { conflict }
        val sdk = h.sdk()
        assertEquals(off, sdk.attest(APP_ID))

        h.transport.on("attest/challenge") { ok(CHALLENGE) }.on("attest/play") { ok(ISSUED) }
        assertEquals(Status.ATTESTED, sdk.attest("app_other")!!.status)
        assertEquals(off, sdk.attest(APP_ID))
        // A restarted app learns the owner's current setting from the server.
        assertEquals(Status.ATTESTED, h.sdk().attest(APP_ID)!!.status)

        val paths = listOf("attest/challenge", "attest/challenge", "attest/play", "attest/challenge", "attest/play")
        assertEquals(paths, h.transport.paths())
    }

    @Test
    fun `other refusals of the challenge are still failures`() = runTest {
        val h = Harness(FakeProvider())
        h.transport.on("attest/challenge") { HttpResponse(404, """{"message":"App not found"}""") }
        val sdk = h.sdk()

        val result = sdk.attest(APP_ID)!!

        assertEquals(Status.FAILED, result.status)
        assertEquals(404, (result.error as LinkRunwayException).status)
        // A failure before the provider is asked starts no pause, so the next call asks again.
        h.transport.on("attest/challenge") { conflict }
        assertEquals(off, sdk.attest(APP_ID))
        assertEquals(2, h.transport.requests.size)
    }

    @Test
    fun `a 409 that arrives after consent was withdrawn reports nothing`() = runTest {
        val h = Harness(FakeProvider())
        lateinit var sdk: LinkRunway
        h.transport.on("attest/challenge") { sdk.setConsent(false); conflict }
        sdk = h.sdk()

        assertNull(sdk.attest(APP_ID))

        assertTrue(h.state.isEmpty())
    }
}
