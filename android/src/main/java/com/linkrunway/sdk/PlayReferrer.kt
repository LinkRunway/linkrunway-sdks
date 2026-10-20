package com.linkrunway.sdk

import android.content.Context
import com.android.installreferrer.api.InstallReferrerClient
import com.android.installreferrer.api.InstallReferrerStateListener
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal suspend fun playReferrer(context: Context): String? = suspendCancellableCoroutine { continuation ->
    val client = InstallReferrerClient.newBuilder(context.applicationContext).build()
    continuation.invokeOnCancellation { client.endConnection() }
    client.startConnection(object : InstallReferrerStateListener {
        override fun onInstallReferrerSetupFinished(responseCode: Int) {
            if (!continuation.isActive) { client.endConnection(); return }
            try {
                when (responseCode) {
                    InstallReferrerClient.InstallReferrerResponse.OK -> continuation.resume(client.installReferrer.installReferrer)
                    InstallReferrerClient.InstallReferrerResponse.FEATURE_NOT_SUPPORTED -> continuation.resume(null)
                    else -> continuation.resumeWithException(IllegalStateException("Install Referrer unavailable: $responseCode"))
                }
            } catch (error: Exception) {
                if (continuation.isActive) continuation.resumeWithException(error)
            } finally { client.endConnection() }
        }
        override fun onInstallReferrerServiceDisconnected() {
            if (continuation.isActive) continuation.resumeWithException(IllegalStateException("Install Referrer disconnected"))
            client.endConnection()
        }
    })
}

/**
 * This install's Play referrer for the current process. Play asks apps to read it sparingly, so one
 * successful read serves both the first-launch match and the referrer claim. It is held in memory
 * only, never stored, and dropped when consent is withdrawn.
 */
internal class ReferrerSource(private val session: Session, private val reader: suspend (Context) -> String?) {
    private class Read(val value: String?)

    @Volatile private var read: Read? = null

    fun forget() { read = null }

    /** Null means Play has no referrer. Throws when Play reports an error or does not answer in time. */
    suspend fun read(context: Context): String? {
        read?.let { return it.value }
        val fresh = withTimeoutOrNull(TIMEOUT) { Read(reader(context)?.takeIf(String::isNotBlank)) }
            ?: throw IllegalStateException("Install Referrer timed out")
        if (session.consent) read = fresh
        return fresh.value
    }

    // Generous: a Play Store that is not running yet can take several seconds to answer.
    private companion object { const val TIMEOUT = 30_000L }
}
