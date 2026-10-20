package com.linkrunway.sdk

import java.io.ByteArrayOutputStream
import java.io.Closeable
import java.io.DataInputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.CopyOnWriteArrayList
import kotlin.concurrent.thread

/**
 * A minimal HTTP/1.1 server bound to the loopback interface: enough to see exactly what the default
 * transport puts on a socket. One request per connection; nothing leaves the machine.
 */
internal class LoopbackServer : Closeable {
    class Seen(val method: String, val path: String, val headers: Map<String, String>, val body: String)
    class Reply(val status: Int, val body: String = "{}", val headers: Map<String, String> = emptyMap())

    // 127.0.0.1, not getLoopbackAddress(): on Android that is ::1, which "localhost" may not reach first.
    private val socket = ServerSocket(0, 50, InetAddress.getByAddress(byteArrayOf(127, 0, 0, 1)))
    val seen = CopyOnWriteArrayList<Seen>()
    val port: Int get() = socket.localPort
    @Volatile var respond: (Seen) -> Reply = { Reply(200) }

    init {
        thread(isDaemon = true, name = "loopback-server") {
            while (!socket.isClosed) {
                try {
                    socket.accept().use(::serve)
                } catch (error: IOException) {
                    // The server was closed, or a client went away mid-request.
                }
            }
        }
    }

    private fun serve(client: Socket) {
        val input = client.getInputStream().buffered()
        val start = line(input).split(' ')
        val headers = generateSequence { line(input).takeIf(String::isNotEmpty) }
            .associate { it.substringBefore(':').trim().lowercase() to it.substringAfter(':').trim() }
        val body = ByteArray(headers["content-length"]?.toInt() ?: 0).also { DataInputStream(input).readFully(it) }
        val request = Seen(start[0], start[1], headers, body.toString(Charsets.UTF_8))
        seen += request
        val reply = respond(request)
        val bytes = reply.body.toByteArray(Charsets.UTF_8)
        val head = buildString {
            append("HTTP/1.1 ${reply.status} Status\r\n")
            (reply.headers + mapOf("Content-Length" to "${bytes.size}", "Connection" to "close"))
                .forEach { (name, value) -> append("$name: $value\r\n") }
            append("\r\n")
        }
        client.getOutputStream().apply {
            write(head.toByteArray(Charsets.US_ASCII))
            write(bytes)
            flush()
        }
    }

    private fun line(input: InputStream): String {
        val bytes = ByteArrayOutputStream()
        while (true) {
            val next = input.read()
            if (next == -1 || next == '\n'.code) break
            if (next != '\r'.code) bytes.write(next)
        }
        return bytes.toString("UTF-8")
    }

    override fun close() = socket.close()
}
