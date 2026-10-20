package com.linkrunway.sdk

import com.linkrunway.sdk.AttestationResult.Status
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.withTimeout
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.IOException
import java.util.Date

/** Device attestation: bound to the challenge and install, cached until expiry, never in the way of tracking. */
@RunWith(RobolectricTestRunner::class)
class AttestationTest {
    private val minute = 60_000L

    private fun Harness.serve() = apply {
        transport.on("attest/challenge") { ok(CHALLENGE) }.on("attest/play") { ok(ISSUED) }
    }

    private fun Harness.attestations() = transport.bodies("track").map { if (it.has("attestation")) it.getString("attestation") else null }

    @Test
    @Config(sdk = [23, 34])
    fun `the nonce is the unpadded base64url SHA-256 of challenge, dot, install id`() {
        // Expected values come from openssl, Node and Python, not from this code:
        //   printf '%s.%s' "$challenge" "$installId" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='
        assertEquals(
            "429fRq2FfDnzOAg9lUfZFLh83YvzHwYeRoxSHnXHE5I",
            attestationNonce("q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA", "3f2b8c1e-5d4a-4e6f-9a7b-0c1d2e3f4a5b"),
        )
        // These two digests contain the characters that differ between base64 and base64url.
        assertEquals("qz1f31eiI2DR1RGKwtDIdcFEGqk71efy-WRFdY1ljfQ", attestationNonce("abc", "00000000-0000-4000-8000-000000000000"))
        assertEquals("1A4Pm0Iij3lur6rPkVaUXA65_05edVujBk4K-OPuxHk", attestationNonce("challenge-1", "00000000-0000-4000-8000-000000000000"))
    }

    @Test
    @Config(sdk = [23, 34])
    fun `an attestation is cached until it expires, across restarts`() = runTest {
        val provider = FakeProvider()
        val h = Harness(provider).serve()
        val sdk = h.sdk()

        val first = sdk.attest(APP_ID)!!

        assertEquals(AttestationResult(Status.ATTESTED, Date(NOW + 24 * HOUR)), first)
        val cached = first.copy(cached = true)
        assertEquals(cached, sdk.attest(APP_ID))
        h.clock = NOW + 23 * HOUR
        assertEquals(cached, h.sdk().attest(APP_ID))
        assertEquals(listOf("attest/challenge", "attest/play"), h.transport.paths())
        assertEquals(1, provider.nonces.size)

        // Inside the last minute the token is treated as expired and replaced.
        h.clock = NOW + 24 * HOUR - 30_000
        h.transport.on("attest/play") { HttpResponse(201, """{"attestation":"att.second","expiresAt":"2027-01-17T08:00:00Z"}""") }
        val renewed = sdk.attest(APP_ID)!!

        assertEquals(AttestationResult(Status.ATTESTED, Date(NOW + 48 * HOUR)), renewed)
        assertEquals(4, h.transport.requests.size)
        sdk.track("OPEN")
        assertEquals(listOf<String?>("att.second"), h.attestations())
    }

    @Test
    fun `events carry the attestation only while it is valid`() = runTest {
        val h = Harness(FakeProvider()).serve()
        val sdk = h.sdk()

        sdk.track("OPEN")
        sdk.attest(APP_ID)
        sdk.track("OPEN")
        h.clock = NOW + 24 * HOUR - 61_000
        sdk.track("OPEN")
        h.clock = NOW + 24 * HOUR - 59_000
        sdk.track("OPEN")
        h.clock = NOW + 25 * HOUR
        h.sdk().track("OPEN")

        assertEquals(listOf(null, "att.signed", "att.signed", null, null), h.attestations())
    }

    @Test
    fun `a failing provider is reported and tracking continues without an attestation`() = runTest {
        val h = Harness(FakeProvider { throw IOException("Play Integrity unavailable") }).serve()
        val sdk = h.sdk()

        val result = sdk.attest(APP_ID)!!

        assertEquals(Status.FAILED, result.status)
        assertTrue(result.error is IOException)
        assertEquals("Play Integrity unavailable", result.error!!.message)
        assertNull(result.expiresAt)
        assertEquals(listOf("attest/challenge"), h.transport.paths())
        assertNull(h.stored("attestation"))
        assertTrue(sdk.track("OPEN") != null)
        assertEquals(listOf<String?>(null), h.attestations())
    }

    @Test
    fun `after a refusal the provider is not asked again for five minutes`() = runTest {
        var refuse = true
        val provider = FakeProvider { if (refuse) throw IOException("Device integrity not met") else "play-integrity-token-0001" }
        val h = Harness(provider).serve()
        val sdk = h.sdk()

        val refused = sdk.attest(APP_ID)!!
        refuse = false
        h.clock = NOW + 5 * minute - 1

        // Each provider token counts against the app's Play Integrity quota.
        assertEquals(refused, sdk.attest(APP_ID))
        assertEquals(1, provider.nonces.size)
        assertEquals(1, h.transport.requests.size)

        h.clock = NOW + 5 * minute
        assertEquals(Status.ATTESTED, sdk.attest(APP_ID)!!.status)
        assertEquals(2, provider.nonces.size)
    }

    @Test
    fun `a failure before the provider is asked does not start the pause`() = runTest {
        val h = Harness(FakeProvider())
        h.transport.on("attest/challenge") { throw IOException("offline") }
        val sdk = h.sdk()

        assertTrue(sdk.attest(APP_ID)!!.error is IOException)
        assertTrue(sdk.attest("")!!.error is IllegalArgumentException)

        h.serve()
        assertEquals(Status.ATTESTED, sdk.attest(APP_ID)!!.status)
    }

    @Test
    fun `a missing Play Integrity library is a failed attestation, not a crash`() = runTest {
        val h = Harness(FakeProvider { throw NoClassDefFoundError("com/google/android/play/core/integrity/IntegrityManagerFactory") }).serve()

        val result = h.sdk().attest(APP_ID)!!

        assertEquals(Status.FAILED, result.status)
        assertTrue(result.error is NoClassDefFoundError)
    }

    @Test
    fun `a provider that never answers, or times out itself, fails after a bounded wait`() = runTest {
        val silent = Harness(FakeProvider { awaitCancellation() }).serve()
        val result = silent.sdk().attest(APP_ID)!!
        assertEquals(Status.FAILED, result.status)
        assertEquals("Attestation provider timed out", result.error!!.message)

        // A timeout inside the provider is a failure of the provider, not a cancellation of the caller.
        val impatient = Harness(FakeProvider { withTimeout(5) { awaitCancellation() } }).serve()
        val sdk = impatient.sdk()
        assertEquals(Status.FAILED, sdk.attest(APP_ID)!!.status)
        assertTrue(sdk.track("OPEN") != null)
    }

    @Test
    fun `a server refusal is reported and nothing is cached`() = runTest {
        val h = Harness(FakeProvider())
        h.transport.on("attest/challenge") { ok(CHALLENGE) }
            .on("attest/play") { HttpResponse(400, """{"message":"Device does not meet the required integrity level"}""") }
        val sdk = h.sdk()

        val refused = sdk.attest(APP_ID)!!

        assertEquals(Status.FAILED, refused.status)
        assertEquals(400, (refused.error as LinkRunwayException).status)
        assertEquals("Device does not meet the required integrity level", refused.error!!.message)
        assertNull(h.stored("attestation"))

        h.clock = NOW + 5 * minute
        h.transport.on("attest/challenge") { HttpResponse(404, """{"message":"App not found"}""") }
        assertEquals(404, (sdk.attest(APP_ID)!!.error as LinkRunwayException).status)
        sdk.track("OPEN")
        assertEquals(listOf<String?>(null), h.attestations())
    }

    @Test
    fun `malformed answers are failures`() = runTest {
        val h = Harness(FakeProvider())
        val sdk = h.sdk()
        val answers = listOf(
            """{"challengeId":"chl_1"}""" to ISSUED,
            CHALLENGE to """{"attestation":"att.signed"}""",
            CHALLENGE to """{"attestation":"att.signed","expiresAt":"tomorrow"}""",
            CHALLENGE to """{"expiresAt":"2027-01-16T08:00:00.000Z"}""",
        )
        for ((index, answer) in answers.withIndex()) {
            h.clock = NOW + index * 6 * minute
            h.transport.on("attest/challenge") { ok(answer.first) }.on("attest/play") { ok(answer.second) }
            assertEquals(Status.FAILED, sdk.attest(APP_ID)!!.status)
            assertNull(h.stored("attestation"))
        }
        // The first answer never reached the provider; each of the others spent one exchange.
        assertEquals(7, h.transport.requests.size)
    }

    @Test
    fun `without a provider nothing is requested`() = runTest {
        val h = Harness(provider = null).serve()

        assertEquals(AttestationResult(Status.NO_PROVIDER), h.sdk().attest(APP_ID))

        assertTrue(h.transport.requests.isEmpty())
        assertTrue(h.preferences.all.isEmpty())
    }

    @Test
    fun `an attestation belongs to one app and one install`() = runTest {
        val provider = FakeProvider()
        val h = Harness(provider).serve()
        val sdk = h.sdk()
        sdk.attest(APP_ID)

        assertFalse(sdk.attest("app_other")!!.cached)
        assertEquals(4, h.transport.requests.size)

        sdk.setConsent(false)
        sdk.setConsent(true)
        sdk.track("OPEN")
        assertEquals(listOf<String?>(null), h.attestations())
        assertFalse(sdk.attest("app_other")!!.cached)
        // Same challenge, new install ID: the nonce the provider must bind changes with the install.
        assertEquals(3, provider.nonces.size)
        assertEquals(provider.nonces[0], provider.nonces[1])
        assertNotEquals(provider.nonces[1], provider.nonces[2])
    }

    @Test
    fun `server timestamps are read as UTC instants`() {
        assertEquals(NOW, parseInstant("2027-01-15T08:00:00.000Z"))
        assertEquals(NOW + 123, parseInstant("2027-01-15T08:00:00.123Z"))
        assertEquals(NOW, parseInstant("2027-01-15T08:00:00Z"))
        for (odd in listOf("", "2027-01-15", "2027-01-15T08:00:00+02:00", "2027-13-45T08:00:00Z", "tomorrow")) {
            failure<IllegalStateException> { parseInstant(odd) }
        }
    }
}
