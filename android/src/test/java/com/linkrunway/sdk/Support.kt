package com.linkrunway.sdk

import android.app.Application
import android.content.Context
import android.content.SharedPreferences
import org.json.JSONObject
import java.io.File
import org.robolectric.RuntimeEnvironment

internal const val ENDPOINT = "https://go.example.com"
internal const val KEY = "lr_pk_test_0123456789abcdef"
internal const val APP_ID = "app_42"

/** Every stored value is named `<what>:SCOPE`, so two workspaces in one app never share state. */
internal val SCOPE = "$ENDPOINT:${KEY.take(20)}"

/** What a LinkRunway store link places in the Play install referrer. */
internal const val REFERRER = "lr_token=tok.referrer&lr_click_id=clk_1&lr_path=%2Fpromo"

/** 2027-01-15T08:00:00Z, the fixed "now" of every test. */
internal const val NOW = 1_800_000_000_000L
internal const val HOUR = 3_600_000L

internal val UUID_V4 = Regex("^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$")

internal const val MATCHED = """{"matched":true,"method":"REFERRER","clickId":"clk_1","clickToken":"tok.matched",
    "path":"/promo","url":"https://example.com/promo","metadata":{"campaign":"spring","rank":3,"vip":true,"note":null}}"""
internal const val CHALLENGE = """{"challengeId":"chl_1","challenge":"q83vEjRWeJCrze8SNFZ4kKvN7xI0VniQq83vEjRWeJA"}"""
internal const val ISSUED = """{"attestation":"att.signed","expiresAt":"2027-01-16T08:00:00.000Z"}"""

/** The claim endpoint's two kinds of answer: 202 while a network has not reported the click, then a final one. */
internal val PENDING = HttpResponse(202, """{"claims":[{"provider":"GOOGLE_ADS","status":"PENDING"}],"pending":true,"retryAfterSeconds":3600}""")
internal val RECORDED = HttpResponse(200, """{"claims":[{"provider":"META","status":"NO_KEY"},{"provider":"GOOGLE_ADS","status":"RECORDED"}],"pending":false}""")

internal fun ok(json: String = "{}") = HttpResponse(200, json)

/** The [T] thrown by [block]. Anything else, or nothing, fails the test. */
internal inline fun <reified T : Throwable> failure(block: () -> Unit): T {
    try {
        block()
    } catch (error: Throwable) {
        if (error is T) return error
        throw error
    }
    throw AssertionError("Expected ${T::class.java.simpleName}, but nothing was thrown")
}

/** Records every request and answers from a per-path handler, so no test touches the network. */
internal class FakeTransport : HttpTransport {
    val requests = mutableListOf<HttpRequest>()
    private val routes = mutableMapOf<String, suspend (HttpRequest) -> HttpResponse>()

    fun on(path: String, handler: suspend (HttpRequest) -> HttpResponse) = apply { routes[path] = handler }

    override suspend fun send(request: HttpRequest): HttpResponse {
        requests += request
        return routes[path(request)]?.invoke(request) ?: ok()
    }

    fun paths() = requests.map(::path)
    fun bodies(path: String) = requests.filter { path(it) == path }.map { JSONObject(it.body) }
    fun body(path: String) = bodies(path).single()

    private fun path(request: HttpRequest) = request.url.substringAfter("/v1/")
}

/** Answers with a fixed token and remembers the nonces it was asked to bind. */
internal class FakeProvider(private val answer: suspend (String) -> String = { "play-integrity-token-0001" }) : AttestationProvider {
    val nonces = mutableListOf<String>()
    override suspend fun token(nonce: String): String {
        nonces += nonce
        return answer(nonce)
    }
}

/** One app install: its storage, clock, Play referrer and server, shared by every SDK instance made from it. */
internal class Harness(val provider: AttestationProvider? = null, var referrer: String? = null) {
    val context: Application = RuntimeEnvironment.getApplication()
    val transport = FakeTransport()
    var clock = NOW
    var referrerReads = 0
    var referrerError: Exception? = null
    val preferences: SharedPreferences get() = context.getSharedPreferences("linkrunway", Context.MODE_PRIVATE)

    /** The file Android never backs up, whose presence tells this install's state from a restored copy. */
    val sentinel: File get() = File(context.noBackupFilesDir, "linkrunway")

    /** Everything stored, apart from the flag that pairs the preferences with [sentinel]. */
    val state: Map<String, Any?> get() = preferences.all - "guard"

    /** A new SDK instance, as after a process restart. Consent is on unless a test turns it off. */
    fun sdk(consent: Boolean = true): LinkRunway {
        val read: suspend (Context) -> String? = {
            referrerReads++
            referrerError?.let { throw it }
            referrer
        }
        return LinkRunway(context, ENDPOINT, KEY, provider, transport, read) { clock }.apply { if (consent) setConsent(true) }
    }

    /** The stored value named `<name>:SCOPE<suffix>`, or null. */
    fun stored(name: String, suffix: String = ""): Any? = preferences.all["$name:$SCOPE$suffix"]
}
