package com.linkrunway.sdk

import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.linkrunway.sdk.LoopbackServer.Reply
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

/**
 * A smoke test on a real Android runtime: the default HTTP transport, real SharedPreferences, the
 * real Play Install Referrer client and the real Play Integrity library, against an HTTP server
 * inside the test process. It proves the plumbing on a device. It cannot prove a Play-distributed
 * install referrer or an integrity verdict: the test package is not installed from Google Play.
 */
@RunWith(AndroidJUnit4::class)
class SmokeTest {
    private val context = InstrumentationRegistry.getInstrumentation().targetContext
    private val server = LoopbackServer()
    private val key = "lr_pk_test_0123456789abcdef"
    private val matched = """{"matched":true,"method":"PROBABILISTIC","clickId":"clk_1","clickToken":"tok.matched",
        "path":"/promo","url":"https://example.com/promo","metadata":{"campaign":"spring"}}"""

    @Before
    fun clean() {
        context.getSharedPreferences("linkrunway", 0).edit().clear().commit()
        File(context.noBackupFilesDir, "linkrunway").delete()
    }

    @After
    fun stop() = server.close()

    private fun sdk(attestation: AttestationProvider? = null) =
        LinkRunway(context, "http://localhost:${server.port}", key, attestation).apply { setConsent(true) }

    @Test
    fun firstLaunchReachesTheServerThroughTheDefaultTransport() = runBlocking {
        server.respond = { request ->
            when (request.path) {
                "/v1/installs/match" -> Reply(200, matched)
                "/v1/track" -> Reply(201, """{"id":"evt_1","attributed":true,"duplicate":false}""")
                else -> Reply(200, """{"claims":[],"pending":false}""")
            }
        }
        val sdk = sdk()

        val result = withTimeout(60_000) { sdk.install(context) }
        val claim = withTimeout(60_000) { sdk.submitReferrerClaim("app_42") }!!

        assertEquals(true, result!!.getBoolean("attributed"))
        val (match, event) = server.seen
        val tv = context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
        assertEquals("POST", match.method)
        assertEquals("/v1/installs/match", match.path)
        assertEquals("LinkRunwaySDK/0.2.1 ${if (tv) "AndroidTV" else "Android"}", match.headers["user-agent"])
        assertEquals("Bearer $key", match.headers["authorization"])
        assertEquals("application/json", match.headers["content-type"])
        val body = JSONObject(match.body)
        Log.i(TAG, "match request on ${Build.VERSION.RELEASE}: $body")
        assertEquals(sdk.installId(), body.getString("installId"))
        assertEquals(if (tv) "androidtv" else "android", body.getString("platform"))
        assertEquals(Device.osVersion(Build.VERSION.RELEASE), body.optString("osVersion").ifEmpty { null })
        assertTrue(body.getString("language").matches(Regex("^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$")))

        assertEquals("/v1/track", event.path)
        val install = JSONObject(event.body)
        assertEquals("INSTALL", install.getString("type"))
        assertEquals("tok.matched", install.getString("clickToken"))
        assertEquals(sdk.installId(), install.getString("installId"))

        // What Play reports for this package decides whether there is a referrer to claim.
        val referrer = body.optString("referrer")
        Log.i(TAG, "referrer claim: ${claim.status} for a referrer of ${referrer.length} characters")
        val expected = if (referrer.isEmpty()) ReferrerClaimResult.Status.NO_REFERRER else ReferrerClaimResult.Status.SUBMITTED
        assertEquals(expected, claim.status)

        // A second launch of the same install sends nothing more and keeps its identity.
        val sent = server.seen.size
        val restarted = sdk()
        assertNull(restarted.install(context))
        assertEquals(true, restarted.matchInstall(context)!!.cached)
        assertEquals("tok.matched", restarted.attributionToken())
        assertEquals(sdk.installId(), restarted.installId())
        assertEquals(sent, server.seen.size)

        // Withdrawing consent leaves nothing but boolean markers on the device.
        restarted.setConsent(false)
        assertNull(restarted.installId())
        assertTrue(context.getSharedPreferences("linkrunway", 0).all.values.all { it is Boolean })
    }

    @Test
    fun stateCopiedWithoutTheNoBackupFileIsDiscarded() = runBlocking {
        val first = sdk()
        first.track("OPEN")
        val original = first.installId()
        assertEquals(original, sdk().installId())

        assertTrue(File(context.noBackupFilesDir, "linkrunway").delete())

        assertNotEquals(original, sdk().installId())
    }

    @Test
    fun theNonceMatchesTheServerVectorOnThisRuntime() {
        assertEquals(
            "429fRq2FfDnzOAg9lUfZFLh83YvzHwYeRoxSHnXHE5I",
            attestationNonce("q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA", "3f2b8c1e-5d4a-4e6f-9a7b-0c1d2e3f4a5b"),
        )
    }

    @Test
    fun playIntegrityAnswersOrFailsWithoutBlockingTracking() = runBlocking {
        server.respond = { request ->
            when (request.path) {
                "/v1/attest/challenge" -> Reply(200, """{"challengeId":"chl_1","challenge":"q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA"}""")
                "/v1/attest/play" -> Reply(201, """{"attestation":"att.signed","expiresAt":"2099-01-01T00:00:00.000Z"}""")
                else -> Reply(200)
            }
        }
        for (mode in PlayIntegrityAttestation.Mode.entries) {
            clean()
            // No Cloud project is linked to this test package, so Play is expected to refuse. If it
            // ever issued a token, the stub server above would accept it; tracking works either way.
            val sdk = sdk(PlayIntegrityAttestation(context, 123456789012L, mode))

            val result = withTimeout(120_000) { sdk.attest("app_42") }!!

            Log.i(TAG, "Play Integrity $mode: ${result.status} ${result.error}")
            assertTrue(result.status != AttestationResult.Status.NO_PROVIDER)
            assertNotNull(withTimeout(60_000) { sdk.track("OPEN") })
        }
    }

    private companion object { const val TAG = "LinkRunwaySmoke" }
}
