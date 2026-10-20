package com.linkrunway.sdk

import android.content.Context
import com.google.android.gms.tasks.Task
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.IntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityException
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenProvider
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import com.google.android.play.core.integrity.model.StandardIntegrityErrorCode
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.Executor
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/**
 * An [AttestationProvider] backed by the Play Integrity API.
 *
 * The SDK compiles against Play Integrity but does not ship it. To use this class, add
 * `com.google.android.play:integrity` to your app. [cloudProjectNumber] is the number of the Google
 * Cloud project that has the Play Integrity API enabled and is linked to the app in Play Console.
 * Each token counts against that project's daily Play Integrity quota.
 */
class PlayIntegrityAttestation @JvmOverloads constructor(
    context: Context,
    private val cloudProjectNumber: Long,
    private val mode: Mode = Mode.CLASSIC,
) : AttestationProvider {
    enum class Mode {
        /**
         * A classic request: the nonce travels as its `nonce`. The server can verify it whether
         * Google decodes the token or the workspace manages its own response encryption keys.
         */
        CLASSIC,

        /**
         * A standard request: the nonce travels as its `requestHash`. Only Google can decode these
         * tokens, so the app's Play Integrity settings in LinkRunway must use Google decoding.
         */
        STANDARD,
    }

    private val context = context.applicationContext ?: context
    private val preparing = Mutex()
    @Volatile private var provider: StandardIntegrityTokenProvider? = null

    override suspend fun token(nonce: String): String = if (mode == Mode.CLASSIC) classic(nonce) else standard(nonce)

    private suspend fun classic(nonce: String): String {
        val request = IntegrityTokenRequest.builder().setNonce(nonce).setCloudProjectNumber(cloudProjectNumber).build()
        return IntegrityManagerFactory.create(context).requestIntegrityToken(request).await().token()
    }

    private suspend fun standard(hash: String): String {
        val request = StandardIntegrityTokenRequest.builder().setRequestHash(hash).build()
        return try {
            prepared().request(request).await().token()
        } catch (error: StandardIntegrityException) {
            // A token provider that was kept too long expires. Play asks for a new one; try it once.
            if (error.errorCode != StandardIntegrityErrorCode.INTEGRITY_TOKEN_PROVIDER_INVALID) throw error
            provider = null
            prepared().request(request).await().token()
        }
    }

    // The warm-up is the slow, quota-counted step, so one prepared provider serves later requests.
    private suspend fun prepared(): StandardIntegrityTokenProvider = preparing.withLock {
        provider ?: IntegrityManagerFactory.createStandard(context)
            .prepareIntegrityToken(PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(cloudProjectNumber).build())
            .await().also { provider = it }
    }
}

private val direct = Executor { it.run() }

/** Suspends until the Play services task finishes, resuming on the thread that completes it. */
internal suspend fun <T> Task<T>.await(): T = suspendCancellableCoroutine { continuation ->
    addOnCompleteListener(direct) { task ->
        val error = task.exception
        when {
            error != null -> continuation.resumeWithException(error)
            task.isCanceled -> continuation.cancel()
            else -> continuation.resume(task.result)
        }
    }
}
