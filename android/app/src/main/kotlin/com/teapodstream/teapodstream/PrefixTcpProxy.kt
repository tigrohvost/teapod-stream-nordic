package com.teapodstream.teapodstream

import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore
import java.util.concurrent.SynchronousQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Bounded loopback transport, admitted by UID or a per-session CONNECT credential. */
class PrefixTcpProxy(
    private val targetHost: String,
    private val targetPort: Int,
    private val prefix: ByteArray,
    // Shadowsocks has no mux here: every app TCP connection is one client, and a
    // browser plus messengers easily hold more than a few dozen at once.
    private val maxClients: Int = 256,
    private val firstBlockTimeoutMs: Int = 5000,
    private val connectUpstream: (Socket, String, Int) -> Unit = { socket, host, port ->
        socket.connect(InetSocketAddress(host, port), 5000)
    },
    private val connectRequest: ((Socket) -> Boolean)? = null,
    private val clientAllowed: (Socket) -> Boolean,
) {
    private val listener = ServerSocket(0, 64, InetAddress.getByName("127.0.0.1"))
    val localPort: Int get() = listener.localPort
    private val sockets = ConcurrentHashMap.newKeySet<Socket>()
    private val slots = Semaphore(maxClients)
    @Volatile private var running = true
    // Two threads per client (one per direction), created on demand and reclaimed
    // after 30 s idle; the slot semaphore bounds them, the margin covers a relay
    // whose upload task is still unwinding after its slot was released.
    private val workers = ThreadPoolExecutor(0, maxClients * 2 + 16, 30, TimeUnit.SECONDS,
        SynchronousQueue<Runnable>(), { r -> Thread(r, "prefix-relay").apply { isDaemon = true } })
    private var acceptThread: Thread? = null

    fun start() {
        check(acceptThread == null)
        acceptThread = Thread {
            while (running) {
                val client = try { listener.accept() } catch (_: Exception) { break }
                val allowed = try { clientAllowed(client) } catch (_: Exception) { false }
                if (!running || !allowed || !slots.tryAcquire()) { client.close(); continue }
                sockets.add(client)
                try { workers.execute { relay(client) } } catch (_: Exception) {
                    close(client); slots.release()
                }
            }
        }.apply { name = "prefix-accept"; isDaemon = true; start() }
    }

    private fun relay(client: Socket) {
        val upstream = Socket()
        sockets.add(upstream)
        try {
            if (!running) return
            client.soTimeout = firstBlockTimeoutMs
            if (connectRequest != null) {
                if (!connectRequest.invoke(client) || !running) return
                connectUpstream(upstream,targetHost,targetPort)
                client.getOutputStream().write("HTTP/1.1 200 Connection Established\r\n\r\n".toByteArray())
            } else {
                val first = ByteArray(65536)
                val count = client.getInputStream().read(first)
                if (count <= 0 || !running) return
                connectUpstream(upstream, targetHost, targetPort)
                upstream.getOutputStream().write(prefix + first.copyOf(count))
                upstream.getOutputStream().flush()
            }
            client.soTimeout = 0
            val uploaded = java.util.concurrent.CountDownLatch(1)
            workers.execute {
                try { client.getInputStream().copyTo(upstream.getOutputStream()) }
                catch (_: Exception) { close(upstream); close(client) }
                finally {
                    try { upstream.shutdownOutput() } catch (_: Exception) {}
                    uploaded.countDown()
                }
            }
            upstream.getInputStream().copyTo(client.getOutputStream())
            try { client.shutdownOutput() } catch (_: Exception) {}
            uploaded.await() // Preserve TCP half-close; stop() closes sockets and interrupts this wait.
        } catch (_: Exception) {
            // Avoid endpoints or credentials in diagnostics.
        } finally { close(upstream); close(client); slots.release() }
    }

    private fun close(socket: Socket) {
        try { socket.close() } catch (_: Exception) {}
        sockets.remove(socket)
    }

    fun stop() {
        running = false
        listener.close()
        sockets.toList().forEach(::close)
        workers.shutdownNow()
        acceptThread?.join(1000)
        sockets.toList().forEach(::close)
        workers.awaitTermination(2000, TimeUnit.MILLISECONDS)
    }
}
