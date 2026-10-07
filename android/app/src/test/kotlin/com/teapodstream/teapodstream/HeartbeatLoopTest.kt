package com.teapodstream.teapodstream

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.InputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/** Runs the real monitor loop against a local fake SOCKS5 proxy, with millisecond timings. */
class HeartbeatLoopTest {

    /** Answers probes like xray when [healthy], otherwise drops every connection. */
    private class FakeProxy : AutoCloseable {
        @Volatile var healthy = false
        private val server = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
        val port: Int = server.localPort

        init {
            Thread {
                while (!server.isClosed) {
                    val client = try { server.accept() } catch (_: Exception) { break }
                    Thread { serve(client) }.apply { isDaemon = true }.start()
                }
            }.apply { isDaemon = true }.start()
        }

        private fun serve(client: Socket) = client.use {
            if (!healthy) return
            val inp = it.getInputStream()
            val out = it.getOutputStream()
            readN(inp, 4)                                  // greeting: VER NMETHODS 0 2
            out.write(byteArrayOf(5, 0))                   // no auth
            val head = readN(inp, 5)                       // VER CMD RSV ATYP=3 LEN
            readN(inp, head[4].toInt() + 2)                // domain + port
            out.write(byteArrayOf(5, 0, 0, 1, 0, 0, 0, 0, 0, 0))
            val req = StringBuilder()
            while (!req.endsWith("\r\n\r\n")) {
                val b = inp.read()
                if (b < 0) return
                req.append(b.toChar())
            }
            out.write("HTTP/1.1 204 No Content\r\n\r\n".toByteArray())
            out.flush()
        }

        private fun readN(inp: InputStream, n: Int): ByteArray {
            val buf = ByteArray(n)
            var read = 0
            while (read < n) {
                val r = inp.read(buf, read, n - read)
                if (r < 0) throw IllegalStateException("eof")
                read += r
            }
            return buf
        }

        override fun close() = server.close()
    }

    /** Mirrors XrayVpnService's wiring of the streak and backoff. */
    private class FakeDeps(override val socksPort: Int, private val backoff: (Int) -> Long) :
        HeartbeatMonitor.Deps {
        @Volatile var up = true
        val streak = AtomicInteger(0)
        val reconnects = LinkedBlockingQueue<Long>()

        override val running: Boolean get() = up
        override val tunModeActive = false
        override fun socksAuth() = "" to ""
        override fun isTunRunning() = true
        override fun tunActiveConnections() = 0L
        override fun tunLastRxActivityMs() = 0L
        override fun tunStatsLine() = ""
        override fun hasDirectInternet() = true
        override fun requestReconnect(afterProbeFailure: Boolean) {
            if (afterProbeFailure) streak.incrementAndGet()
            reconnects.add(System.currentTimeMillis())
        }
        override fun onProbeSuccess() = streak.set(0)
        override fun reconnectBackoffMs() = backoff(streak.get())
        override fun log(level: String, message: String) {}
    }

    private val proxy = FakeProxy()
    private var monitor: HeartbeatMonitor? = null
    private var deps: FakeDeps? = null

    private fun start(isReconnect: Boolean = false, streak: Int = 0, backoff: (Int) -> Long): FakeDeps {
        val d = FakeDeps(proxy.port, backoff).also { it.streak.set(streak) }
        deps = d
        monitor = HeartbeatMonitor(d, intervalMs = 50, warmupTimeoutMs = 100, retryDelayMs = 10)
            .also { it.start(isReconnect) }
        return d
    }

    @After
    fun tearDown() {
        deps?.up = false
        monitor?.stop()
        proxy.close()
    }

    @Test
    fun `dead tunnel after a healthy session reconnects without delay`() {
        val d = start { HeartbeatMonitor.backoffForStreak(it) }
        assertNotNull("expected a reconnect", d.reconnects.poll(3, TimeUnit.SECONDS))
        assertEquals(1, d.streak.get())
    }

    @Test
    fun `failing again after a reconnect defers the next one`() {
        val startedAt = System.currentTimeMillis()
        val d = start(streak = 1) { if (it > 0) 1_000L else 0L }
        val at = d.reconnects.poll(5, TimeUnit.SECONDS)
        assertNotNull("expected the deferred reconnect to fire", at)
        assertTrue("reconnect must wait out the backoff", at!! - startedAt >= 1_000L)
    }

    @Test
    fun `a successful probe cancels a deferred reconnect`() {
        val d = start(streak = 1) { if (it > 0) 1_000L else 0L }
        Thread.sleep(500)          // three failures in, the reconnect is now deferred
        proxy.healthy = true
        assertNull("server came back — no reconnect", d.reconnects.poll(2_500, TimeUnit.MILLISECONDS))
        assertEquals(0, d.streak.get())
    }

    @Test
    fun `warmup timeout after a reconnect also honours the backoff`() {
        val startedAt = System.currentTimeMillis()
        val d = start(isReconnect = true, streak = 1) { if (it > 0) 1_000L else 0L }
        val at = d.reconnects.poll(5, TimeUnit.SECONDS)
        assertNotNull(at)
        assertTrue(at!! - startedAt >= 1_000L)
    }
}
