package com.linkrunway.sdk

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONException
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/** One JSON POST built by the SDK. [headers] carry the publishable key, so never log them. */
class HttpRequest(val url: String, val headers: Map<String, String>, val body: String)

class HttpResponse(val status: Int, val body: String)

/**
 * Executes the SDK's requests. Replace it to route through your own HTTP stack or to test without a
 * network. Report transport failures as [IOException], return every HTTP status (errors included)
 * as a response, and do not follow redirects.
 */
interface HttpTransport {
    suspend fun send(request: HttpRequest): HttpResponse
}

/** The default transport: `HttpURLConnection` on the IO dispatcher, no redirects, bounded timeouts. */
class UrlConnectionTransport : HttpTransport {
    override suspend fun send(request: HttpRequest): HttpResponse = withContext(Dispatchers.IO) {
        val connection = URL(request.url).openConnection() as HttpURLConnection
        try {
            connection.requestMethod = "POST"
            connection.instanceFollowRedirects = false
            connection.connectTimeout = 10_000
            connection.readTimeout = 15_000
            connection.doOutput = true
            request.headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
            connection.outputStream.use { it.write(request.body.toByteArray(Charsets.UTF_8)) }
            val status = connection.responseCode
            val stream = if (status in 200..299) connection.inputStream else connection.errorStream
            HttpResponse(status, stream?.bufferedReader()?.use { it.readText() } ?: "")
        } finally { connection.disconnect() }
    }
}

class LinkRunwayException(val status: Int, message: String) : Exception(message)

internal class Reply(val status: Int, val json: JSONObject)

/** Builds every request the SDK sends and retries transient failures. [allowed] is the consent gate. */
internal class ApiClient(
    endpoint: String,
    publishableKey: String,
    userAgent: String,
    private val transport: HttpTransport,
    private val allowed: () -> Boolean,
) {
    private val base = endpoint.trimEnd('/')
    private val headers = mapOf(
        "User-Agent" to userAgent,
        "Content-Type" to "application/json",
        "Authorization" to "Bearer $publishableKey",
    )

    init {
        require(publishableKey.startsWith("lr_pk_")) { "Use a publishable key in mobile apps" }
        val url = URL(endpoint)
        // Plain HTTP is accepted only for a development server on this machine or the emulator host.
        require(url.protocol == "https" || (url.protocol == "http" && url.host in LOCAL_HOSTS)) { "HTTPS is required" }
    }

    suspend fun post(path: String, body: JSONObject): JSONObject = send(path, body).json

    /**
     * Three attempts: 429, 5xx and transport failures wait 300 ms, then 600 ms, before the next one.
     * [retryServerErrors] is off for a request the server cannot process twice.
     */
    suspend fun send(path: String, body: JSONObject, retryServerErrors: Boolean = true): Reply {
        val request = HttpRequest("$base/v1/$path", headers, body.toString())
        for (attempt in 0..2) {
            check(allowed()) { "Consent was withdrawn" }
            val response = try {
                transport.send(request)
            } catch (error: IOException) {
                if (attempt == 2) throw error
                delay(300L * (1 shl attempt)); continue
            }
            val status = response.status
            if ((status == 429 || (status >= 500 && retryServerErrors)) && attempt < 2) {
                delay(300L * (1 shl attempt)); continue
            }
            if (status !in 200..299) throw LinkRunwayException(status, message(response.body))
            return try {
                Reply(status, if (response.body.isBlank()) JSONObject() else JSONObject(response.body))
            } catch (error: JSONException) { throw LinkRunwayException(status, "Malformed response") }
        }
        error("Request failed")
    }

    private fun message(body: String) = try {
        JSONObject(body).optString("message", "Request failed")
    } catch (error: JSONException) { "Request failed" }

    private companion object { val LOCAL_HOSTS = listOf("localhost", "10.0.2.2") }
}
