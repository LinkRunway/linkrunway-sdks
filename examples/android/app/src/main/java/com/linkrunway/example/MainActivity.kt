package com.linkrunway.example

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.widget.CheckBox
import android.widget.LinearLayout
import android.widget.TextView
import com.linkrunway.sdk.LinkRunway
import com.linkrunway.sdk.PlayIntegrityAttestation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.MainScope
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * The whole LinkRunway integration on one screen. Nothing is sent until the box is ticked.
 * The endpoint, key and app ID come from app/build.gradle.kts, where they are placeholders.
 */
class MainActivity : Activity() {
    private val scope = MainScope()
    private lateinit var runway: LinkRunway
    private lateinit var log: TextView

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Attestation is optional. This build packages Play Integrity only when a project number was given.
        val attestation = BuildConfig.CLOUD_PROJECT_NUMBER.takeIf { it != 0L }?.let { PlayIntegrityAttestation(this, it) }
        runway = LinkRunway(applicationContext, BuildConfig.LINKRUNWAY_ENDPOINT, BuildConfig.LINKRUNWAY_KEY, attestation)
        log = TextView(this)
        val consent = CheckBox(this).apply {
            text = "Allow analytics and attribution"
            setOnCheckedChangeListener { _, allowed -> onConsent(allowed) }
        }
        setContentView(LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(48, 96, 48, 48)
            addView(consent)
            addView(log)
        })
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        scope.launch { report { openLink() } }
    }

    private fun onConsent(allowed: Boolean) {
        // In a real app this follows your own consent flow and is called on every start.
        runway.setConsent(allowed)
        if (!allowed) return show("Consent withdrawn: the SDK erased what it had stored.")
        scope.launch { report { firstLaunch() } }
    }

    private suspend fun firstLaunch() {
        openLink()
        // Once per install: which earlier click or impression, if any, led here.
        val match = runway.matchInstall(applicationContext)
        if (match?.matched == true && !match.cached) show("Matched by ${match.method}. Route to ${match.path} if your app allows that path.")
        // Once per install: the INSTALL event. It uses the match above and never waits on the calls below.
        runway.install(applicationContext)
        show("Referrer claim: ${runway.submitReferrerClaim(BuildConfig.LINKRUNWAY_APP_ID)?.status}")
        show("Attestation: ${runway.attest(BuildConfig.LINKRUNWAY_APP_ID)?.status}")
        runway.track("OPEN")
        show("Sent OPEN for install ${runway.installId()}")
    }

    // A LinkRunway link that opened this activity is the most recent click.
    private suspend fun openLink() {
        val url = intent?.data?.toString() ?: return
        val link = runway.open(url) ?: return
        show("Opened a link to ${link.optString("path")}")
    }

    private suspend fun report(call: suspend () -> Unit) {
        try {
            call()
        } catch (error: CancellationException) {
            throw error
        } catch (error: Exception) {
            show("A LinkRunway call failed: ${error.message}")
        }
    }

    private fun show(line: String) {
        log.append("$line\n")
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }
}
