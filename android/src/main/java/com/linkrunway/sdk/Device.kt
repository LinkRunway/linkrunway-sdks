package com.linkrunway.sdk

import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Resources
import android.os.Build
import java.util.Locale

/**
 * The few coarse facts the SDK reports about where it runs. No advertising ID, Android ID, serial,
 * IMEI, MAC address or other hardware identifier is read anywhere in this SDK.
 */
internal object Device {
    private val version = Regex("^[0-9]{1,3}(\\.[0-9]{1,3}){0,2}$")
    private val language = Regex("^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$")

    /** `androidtv` on devices with the leanback (television) UI, otherwise `android`. */
    fun platform(context: Context) =
        if (context.packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)) "androidtv" else "android"

    fun userAgent(platform: String) =
        "LinkRunwaySDK/${LinkRunway.VERSION} ${if (platform == "androidtv") "AndroidTV" else "Android"}"

    /** The Android release as `major[.minor[.patch]]`, or null for preview or vendor formats. */
    fun osVersion(release: String? = Build.VERSION.RELEASE): String? =
        release.orEmpty().trim().split('.').take(3).joinToString(".").takeIf(version::matches)

    /** A plain language tag such as `en-US`; Unicode extensions and private-use subtags are dropped. */
    fun language(locale: Locale = systemLocale()): String? {
        val tag = locale.toLanguageTag().split('-').takeWhile { it.length > 1 }.joinToString("-")
        return tag.takeIf { it.substringBefore('-') != "und" && it.length <= 35 && language.matches(it) }
    }

    // The user's first system language, which is what a browser on the same device announces.
    private fun systemLocale(): Locale {
        val configuration = Resources.getSystem().configuration
        @Suppress("DEPRECATION")
        val locale = if (Build.VERSION.SDK_INT >= 24) configuration.locales.takeIf { !it.isEmpty }?.get(0)
        else configuration.locale
        return locale ?: Locale.getDefault()
    }
}
