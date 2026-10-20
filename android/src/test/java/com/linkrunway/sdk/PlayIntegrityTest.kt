package com.linkrunway.sdk

import android.os.Looper
import com.google.android.gms.tasks.TaskCompletionSource
import com.google.android.gms.tasks.Tasks
import com.google.android.play.core.integrity.IntegrityServiceException
import com.google.android.play.core.integrity.StandardIntegrityException
import com.google.android.play.core.integrity.model.IntegrityErrorCode
import com.google.android.play.core.integrity.model.StandardIntegrityErrorCode
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf

/**
 * The Play Integrity provider without Google Play: how a Play services task becomes a result, and
 * what the real Play Integrity library reports through the provider on a device that has no Play
 * Store. A successful token and its verdict need a real, Play-certified device.
 */
@RunWith(RobolectricTestRunner::class)
class PlayIntegrityTest {
    @Test
    fun `a finished task resumes with its result or its failure`() = runTest {
        assertEquals("token", Tasks.forResult("token").await())

        val refused = failure<IllegalStateException> { Tasks.forException<String>(IllegalStateException("refused")).await() }
        assertEquals("refused", refused.message)

        failure<CancellationException> { Tasks.forCanceled<String>().await() }
    }

    @Test
    fun `a pending task resumes when it completes`() = runTest {
        val source = TaskCompletionSource<String>()
        val waiting = async { source.task.await() }
        testScheduler.runCurrent()
        assertTrue(waiting.isActive)

        source.setResult("later")

        assertEquals("later", waiting.await())
    }

    /**
     * Play Integrity delivers its results on the main thread, as on a device, so the call runs on
     * another thread while this one keeps the main looper turning.
     */
    private fun attest(h: Harness, mode: PlayIntegrityAttestation.Mode): Pair<LinkRunway, AttestationResult> {
        // Android refuses to bind a service whose package is absent; Robolectric has to be told so.
        shadowOf(h.context).declareActionUnbindable("com.google.android.play.core.expressintegrityservice.BIND_EXPRESS_INTEGRITY_SERVICE")
        h.transport.on("attest/challenge") { ok(CHALLENGE) }
        val provider = PlayIntegrityAttestation(h.context, 123456789012L, mode)
        val sdk = LinkRunway(h.context, ENDPOINT, KEY, provider, h.transport).apply { setConsent(true) }
        val call = CoroutineScope(Dispatchers.IO).async { sdk.attest(APP_ID)!! }
        val deadline = System.currentTimeMillis() + 20_000
        while (!call.isCompleted && System.currentTimeMillis() < deadline) {
            shadowOf(Looper.getMainLooper()).idle()
            Thread.sleep(10)
        }
        assertTrue("Play Integrity did not answer", call.isCompleted)
        return sdk to runBlocking { call.await() }
    }

    @Test
    fun `without the Play Store a standard request fails and tracking continues`() {
        val h = Harness()

        val (sdk, result) = attest(h, PlayIntegrityAttestation.Mode.STANDARD)

        assertEquals(AttestationResult.Status.FAILED, result.status)
        assertEquals(StandardIntegrityErrorCode.PLAY_STORE_NOT_FOUND, (result.error as StandardIntegrityException).errorCode)
        assertEquals(listOf("attest/challenge"), h.transport.paths())
        runBlocking { sdk.track("OPEN") }
        assertFalse(h.transport.body("track").has("attestation"))
    }

    @Test
    fun `without the Play Store a classic request fails and tracking continues`() {
        val h = Harness()

        val (sdk, result) = attest(h, PlayIntegrityAttestation.Mode.CLASSIC)

        assertEquals(AttestationResult.Status.FAILED, result.status)
        assertEquals(IntegrityErrorCode.PLAY_STORE_NOT_FOUND, (result.error as IntegrityServiceException).errorCode)
        assertEquals(listOf("attest/challenge"), h.transport.paths())
        runBlocking { sdk.track("OPEN") }
        assertFalse(h.transport.body("track").has("attestation"))
    }
}
