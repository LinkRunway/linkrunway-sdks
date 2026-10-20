package com.linkrunway.sdk

import android.content.Context
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import org.json.JSONObject

/**
 * Forwards the raw Play install referrer so the server can verify ad-network evidence inside it.
 * One final answer per install; the SDK reads nothing out of the referrer for this itself.
 */
internal class ReferrerClaims(
    private val context: Context,
    private val session: Session,
    private val api: ApiClient,
    private val source: ReferrerSource,
    private val now: () -> Long,
) {
    private val store = session.store
    private val lock = Mutex()

    suspend fun submit(appId: String): ReferrerClaimResult? = lock.withLock {
        if (!session.consent) return null
        if (store.claimSent) return ReferrerClaimResult(ReferrerClaimResult.Status.ALREADY_SUBMITTED)
        // The server asked for a pause before the same referrer is sent again. A wait longer than
        // any pause it can ask for means the clock moved, and is ignored.
        if (store.claimRetryAt - now() in 1..MAX_PAUSE) return ReferrerClaimResult(ReferrerClaimResult.Status.PENDING)
        try {
            require(appId.isNotBlank() && appId.length <= 100) { "appId is the app's ID in the LinkRunway console" }
            val referrer = source.read(context) ?: return ReferrerClaimResult(ReferrerClaimResult.Status.NO_REFERRER)
            check(referrer.length <= LIMIT) { "The install referrer is too long to claim" }
            val installId = session.installId() ?: return null
            val body = JSONObject().put("installId", installId).put("appId", appId).put("referrer", referrer).put("consent", true)
            val reply = api.send("claims/referrer", body)
            // 202: a network has not reported the click yet, and the same referrer may be sent again.
            val pending = reply.status == 202 || reply.json.optBoolean("pending")
            session.commit(installId) { settle(pending, reply.json) } ?: return null
            val status = if (pending) ReferrerClaimResult.Status.PENDING else ReferrerClaimResult.Status.SUBMITTED
            ReferrerClaimResult(status, claimedNetworks(reply.json))
        } catch (error: Exception) {
            error.rethrowIfCancelled()
            // A call cut short by a consent withdrawal has nothing to report.
            if (session.consent) ReferrerClaimResult(ReferrerClaimResult.Status.FAILED, error = error) else null
        }
    }

    private fun settle(pending: Boolean, answer: JSONObject) {
        val time = now()
        val since = store.claimPendingSince.takeIf { it > 0 } ?: time
        // The server looks a pending click up in the network's reports for the current and the
        // previous day, so after two days another attempt cannot succeed.
        if (!pending || time - since >= WINDOW) return store.markClaimSent()
        store.claimPendingSince = since
        store.claimRetryAt = time + (answer.optLong("retryAfterSeconds", 3600) * 1000).coerceIn(MIN_PAUSE, MAX_PAUSE)
    }

    private companion object {
        const val LIMIT = 8000
        const val MIN_PAUSE = 60_000L
        const val MAX_PAUSE = 24 * 3_600_000L
        const val WINDOW = 48 * 3_600_000L
    }
}
