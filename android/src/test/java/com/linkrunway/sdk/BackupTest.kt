package com.linkrunway.sdk

import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Android's Auto Backup and device transfer copy shared preferences to other installs. The SDK's
 * state describes one install, so a copy that arrives on another one is discarded.
 */
@RunWith(RobolectricTestRunner::class)
class BackupTest {
    private fun Harness.serve() = apply {
        transport.on("installs/match") { ok(MATCHED) }.on("claims/referrer") { RECORDED }
            .on("attest/challenge") { ok(CHALLENGE) }.on("attest/play") { ok(ISSUED) }
    }

    private suspend fun Harness.firstLaunch(): LinkRunway = sdk().also {
        it.install(context)
        it.submitReferrerClaim(APP_ID)
        it.attest(APP_ID)
    }

    @Test
    @Config(sdk = [23, 34])
    fun `state restored onto another install is discarded and that install starts fresh`() = runTest {
        val h = Harness(FakeProvider(), REFERRER).serve()
        val original = h.firstLaunch().installId()
        assertEquals(true, h.preferences.all["guard"])
        assertTrue(h.sentinel.exists())

        // A restore brings the preferences file but never the no-backup file.
        assertTrue(h.sentinel.delete())
        val restored = h.sdk()

        assertTrue(h.preferences.all.isEmpty())
        assertNull(restored.attributionToken())
        assertNull(restored.installMatch())
        assertNotEquals(original, restored.installId())

        // The new install has its own first launch: matched, reported and claimed under its own ID.
        restored.install(h.context)
        restored.submitReferrerClaim(APP_ID)
        assertEquals(listOf("installs/match", "track", "claims/referrer"), h.transport.paths().drop(5))
        assertEquals(2, h.transport.bodies("track").map { it.getString("installId") }.toSet().size)
        assertEquals(2, h.transport.bodies("track").map { it.getString("eventId") }.toSet().size)
    }

    @Test
    fun `the same install keeps its state across restarts`() = runTest {
        val h = Harness(FakeProvider(), REFERRER).serve()
        val original = h.firstLaunch().installId()

        val restarted = h.sdk()

        assertEquals(original, restarted.installId())
        assertEquals("tok.matched", restarted.attributionToken())
        assertNull(restarted.install(h.context))
        assertEquals(5, h.transport.requests.size)
    }

    @Test
    fun `state written by an earlier SDK version carries no guard and is kept`() = runTest {
        val h = Harness()
        h.preferences.edit().putString("token:$SCOPE", "tok.legacy").putBoolean("install:token:$SCOPE:sent", true).commit()

        val sdk = h.sdk()

        assertEquals("tok.legacy", sdk.attributionToken())
        assertNull(sdk.install(h.context))
        // Its first write under this version pairs the preferences with the no-backup file.
        sdk.track("OPEN")
        assertEquals(true, h.preferences.all["guard"])
        assertTrue(h.sentinel.exists())
    }

    @Test
    fun `restored state is not read while consent is off and is discarded once it is given`() = runTest {
        val h = Harness(FakeProvider(), REFERRER).serve()
        h.firstLaunch()
        assertTrue(h.sentinel.delete())

        val sdk = h.sdk(consent = false)
        assertNull(sdk.installId())
        assertNull(sdk.install(h.context))
        assertEquals(5, h.transport.requests.size)

        sdk.setConsent(true)
        assertTrue(h.preferences.all.isEmpty())
        sdk.install(h.context)
        assertEquals(listOf("installs/match", "track"), h.transport.paths().drop(5))
    }
}
