package com.linkrunway.sdk

import android.content.Context
import android.net.Uri
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONException
import org.json.JSONObject

/**
 * A cancellation raised inside a call (a timeout, a provider's own scope) is an ordinary failure.
 * It is rethrown only when the calling coroutine itself was cancelled.
 */
internal suspend fun Exception.rethrowIfCancelled() {
    if (this is CancellationException) currentCoroutineContext().ensureActive()
}

/** Resolves an install's first launch on the server, once, and remembers the answer. */
internal class FirstLaunch(
    private val session: Session,
    private val api: ApiClient,
    private val platform: String,
    private val source: ReferrerSource,
) {
    /** [fallbackToken] is set only when the request failed and the caller asked not to be failed by it. */
    class Outcome(val match: InstallMatchResult?, val fallbackToken: String? = null)

    private val store = session.store
    private val lock = Mutex()
    private val unmatched = InstallMatchResult(false, MatchMethod.NONE, cached = true)

    /**
     * The answer available without a request, or null when the server still has to be asked.
     * Matching belongs to the first launch: once it was resolved, or INSTALL was delivered, the
     * server is not asked again, so an upgraded or re-consented install is never matched to an
     * unrelated later click. A resolved match erased by a consent withdrawal reads as unmatched.
     */
    fun stored(): InstallMatchResult? {
        if (!session.consent) return null
        val saved = store.match ?: return unmatched.takeIf { store.matchResolved || store.installSent }
        return try {
            installMatch(JSONObject(saved), cached = true)
        } catch (error: JSONException) { unmatched }
    }

    /**
     * Asks the server which earlier touch, if any, led to this install. With [strict] off (the
     * INSTALL path) a failed request is not thrown: the outcome then carries the LinkRunway token
     * found in the referrer itself, which is what earlier SDK versions sent with INSTALL.
     */
    suspend fun match(context: Context, strict: Boolean): Outcome = lock.withLock {
        if (!session.consent) return Outcome(null)
        stored()?.let { return Outcome(it) }
        // A failed read stops here: asking without the referrer would fix the wrong answer forever.
        val referrer = source.read(context)
        val installId = session.installId() ?: return Outcome(null)
        try {
            val body = JSONObject().put("installId", installId).put("platform", platform)
                .put("osVersion", Device.osVersion()).put("language", Device.language())
                .put("referrer", matchable(referrer)).put("consent", true)
            val answer = api.post("installs/match", body)
            Outcome(session.commit(installId) {
                session.adoptToken(answer.text("clickToken"))
                store.match = JSONObject(answer.toString()).apply { remove("clickToken") }.toString()
                store.matchResolved = true
                installMatch(answer, cached = false)
            })
        } catch (error: Exception) {
            error.rethrowIfCancelled()
            if (strict) throw error
            Outcome(null, referrer?.let { Session.referrerToken(it) })
        }
    }

    // The match contract caps the referrer; an oversized one is reduced to the token it is read for.
    private fun matchable(referrer: String?): String? = when {
        referrer == null || referrer.length <= LIMIT -> referrer
        else -> Session.referrerToken(referrer)?.let { "lr_token=${Uri.encode(it)}" }?.takeIf { it.length <= LIMIT }
    }

    private companion object { const val LIMIT = 4000 }
}
