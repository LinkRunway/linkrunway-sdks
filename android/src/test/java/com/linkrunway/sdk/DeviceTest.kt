package com.linkrunway.sdk

import android.content.pm.PackageManager
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.net.MalformedURLException
import java.util.Locale

/** Platform detection, the coarse facts sent with a match, and the constructor's safety checks. */
@RunWith(RobolectricTestRunner::class)
class DeviceTest {
    // The LinkRunway API: only these user agents are recognised as the SDK.
    private val serverPattern = Regex("^LinkRunwaySDK/[0-9.]+ (iOS|Android|tvOS|AndroidTV|ReactNative|Flutter)$")

    @Test
    @Config(sdk = [23, 34])
    fun `a leanback device is reported as androidtv with the AndroidTV user agent`() = runTest {
        val h = Harness(referrer = REFERRER)
        shadowOf(h.context.packageManager).setSystemFeature(PackageManager.FEATURE_LEANBACK, true)
        val sdk = h.sdk()

        sdk.matchInstall(h.context)
        sdk.track("OPEN")
        sdk.open("https://go.example.com/l/abc")

        assertEquals("androidtv", h.transport.body("installs/match").getString("platform"))
        h.transport.requests.forEach { assertEquals("LinkRunwaySDK/0.2.0 AndroidTV", it.headers["User-Agent"]) }
        assertTrue(serverPattern.matches("LinkRunwaySDK/0.2.0 AndroidTV"))
        // The resolve endpoint accepts ios, android and web only.
        assertEquals("android", h.transport.body("resolve").getString("platform"))
    }

    @Test
    @Config(sdk = [23, 34])
    fun `a phone or tablet is reported as android with the Android user agent`() = runTest {
        val h = Harness()
        val sdk = h.sdk()

        sdk.matchInstall(h.context)
        sdk.track("OPEN")

        assertEquals("android", h.transport.body("installs/match").getString("platform"))
        h.transport.requests.forEach { assertEquals("LinkRunwaySDK/0.2.0 Android", it.headers["User-Agent"]) }
        assertTrue(serverPattern.matches("LinkRunwaySDK/0.2.0 Android"))
        assertEquals("0.2.0", LinkRunway.VERSION)
    }

    @Test
    fun `the OS version is sent only in the form the server accepts`() {
        assertEquals("14", Device.osVersion("14"))
        assertEquals("8.1.0", Device.osVersion("8.1.0"))
        assertEquals("6.0.1", Device.osVersion(" 6.0.1 "))
        assertEquals("12.0.0", Device.osVersion("12.0.0.1"))
        for (odd in listOf(null, "", "VanillaIceCream", "14 QPR2", "S", "1234", "14.", "v14", "14-beta")) {
            assertNull(odd, Device.osVersion(odd))
        }
    }

    @Test
    @Config(sdk = [23, 34])
    fun `the language is a plain tag without extensions or private data`() {
        assertEquals("en-US", Device.language(Locale.US))
        assertEquals("fr", Device.language(Locale.FRENCH))
        assertEquals("zh-Hans-CN", Device.language(Locale.forLanguageTag("zh-Hans-CN")))
        assertEquals("es-419", Device.language(Locale.forLanguageTag("es-419")))
        assertEquals("ja-JP", Device.language(Locale.forLanguageTag("ja-JP-u-ca-japanese")))
        assertEquals("th-TH", Device.language(Locale.forLanguageTag("th-TH-u-nu-thai-x-lvariant-TH")))
        assertEquals("en-US", Device.language(Locale.forLanguageTag("en-US-x-user-12345")))
        // Java keeps three legacy codes internally; the tag a browser sends uses the modern ones.
        assertEquals("he-IL", Device.language(Locale("iw", "IL")))
        assertNull(Device.language(Locale.ROOT))
        assertNull(Device.language(Locale.forLanguageTag("und-US")))
        assertNull(Device.language(Locale.forLanguageTag("x-private")))
    }

    @Test
    @Config(qualifiers = "fr-rCA")
    fun `the match reports the system language, not the JVM default`() = runTest {
        val h = Harness()
        h.sdk().matchInstall(h.context)
        assertEquals("fr-CA", h.transport.body("installs/match").getString("language"))
    }

    @Test
    @Config(sdk = [23])
    fun `the oldest supported Android reports its release and language`() = runTest {
        val h = Harness()
        h.sdk().matchInstall(h.context)
        val body = h.transport.body("installs/match")
        assertEquals("6.0.1", body.getString("osVersion"))
        assertEquals("en-US", body.getString("language"))
    }

    @Test
    fun `secret keys and plain HTTP are refused`() {
        val h = Harness()
        fun create(endpoint: String, key: String = KEY) = LinkRunway(h.context, endpoint, key, transport = h.transport)

        assertEquals("Use a publishable key in mobile apps", failure<IllegalArgumentException> { create(ENDPOINT, "lr_sk_secret") }.message)
        failure<IllegalArgumentException> { create(ENDPOINT, "") }
        assertEquals("HTTPS is required", failure<IllegalArgumentException> { create("http://go.example.com") }.message)
        failure<IllegalArgumentException> { create("http://192.168.1.20:4000") }
        failure<IllegalArgumentException> { create("ftp://localhost") }
        failure<MalformedURLException> { create("go.example.com") }

        // A development server on this machine or on the emulator's host loopback may use HTTP.
        create("http://localhost:4000")
        create("http://10.0.2.2:4000")
        create("https://go.example.com")
        assertTrue(h.transport.requests.isEmpty())
    }
}
