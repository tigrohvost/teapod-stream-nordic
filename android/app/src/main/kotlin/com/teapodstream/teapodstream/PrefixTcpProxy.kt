package com.teapodstream.teapodstream

import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Semaphore
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Bounded, loopback-only transport; only the core's own UID may use it. */
class PrefixTcpProxy(
    private val targetHost: String,
    private val targetPort: Int,
    private val prefix: ByteArray,
    private val maxClients: Int = 32,
    private val firstBlockTimeoutMs: Int = 5000,
    private val clientAllowed: (Socket) -> Boolean,
) {
    private val listener = ServerSocket(0, maxClients, InetAddress.getByName("127.0.0.1"))
    val localPort: Int get() = listener.localPort
    private val sockets = ConcurrentHashMap.newKeySet<Socket>()
    private val slots = Semaphore(maxClients)
    @Volatile private var running = true
    private val workers = ThreadPoolExecutor(maxClients * 2, maxClients * 2, 0, TimeUnit.MILLISECONDS,
        ArrayBlockingQueue<Runnable>(maxClients * 2), { r -> Thread(r, "prefix-relay").apply { isDaemon = true } })
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
            val first = ByteArray(65536)
            val count = client.getInputStream().read(first)
            if (count <= 0 || !running) return
            client.soTimeout = 0
            upstream.connect(InetSocketAddress(targetHost, targetPort), 5000)
            upstream.getOutputStream().write(prefix + first.copyOf(count))
            upstream.getOutputStream().flush()
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
