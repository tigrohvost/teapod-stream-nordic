package com.teapodstream.teapodstream

import org.junit.Assert.*
import org.junit.Test
import java.net.Socket
import java.net.ServerSocket
import java.net.InetAddress
import java.util.concurrent.CompletableFuture
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

class SessionPolicyTest {
    @Test fun emptyOnlyCannotBecomeGlobalVpn() {
        for (packages in listOf(emptyList(), listOf("missing"), listOf("self"))) {
            try {
                AllowedApplications.resolve(packages, 10) { if (it == "self") 10 else null }
                fail("Empty policy accepted")
            } catch (e: ConnectionFailure) { assertEquals("EMPTY_ALLOWED_APPS", e.code) }
        }
        assertEquals(mapOf("installed" to 20), AllowedApplications.resolve(listOf("self", "missing", "installed"), 10) {
            when (it) { "self" -> 10; "installed" -> 20; else -> null }
        })
    }

    @Test fun oldStopRetainsOwnershipPastTimeout() {
        val coordinator = SessionCoordinator()
        val stopEntered = CountDownLatch(1)
        val releaseStop = CountDownLatch(1)
        val blocked = CountDownLatch(1)
        val started = AtomicInteger(0)
        val stop = coordinator.execute {
            coordinator.stopAndAwait(20, { blocked.countDown() }) {
                stopEntered.countDown(); releaseStop.await()
            }
        }
        assertTrue(stopEntered.await(1, TimeUnit.SECONDS))
        val next = coordinator.execute { started.incrementAndGet() }
        assertTrue(blocked.await(1, TimeUnit.SECONDS))
        assertEquals(0, started.get())
        assertFalse(next.isDone)
        releaseStop.countDown()
        stop.get(1, TimeUnit.SECONDS); next.get(1, TimeUnit.SECONDS)
        assertEquals(1, started.get())
    }

    @Test fun simultaneousReconnectsAreCoalescedAndOldCallbacksInvalidated() {
        val c = SessionCoordinator()
        val id = c.invalidate()
        val entered = CountDownLatch(1)
        val release = CountDownLatch(1)
        val count = AtomicInteger(0)
        c.reconnect(id) { count.incrementAndGet(); entered.countDown(); release.await() }
        assertTrue(entered.await(1, TimeUnit.SECONDS))
        repeat(20) { c.reconnect(id) { count.incrementAndGet() } }
        c.invalidate()
        assertFalse(c.isCurrent(id))
        release.countDown()
        c.execute {}.get(1, TimeUnit.SECONDS)
        assertEquals(1, count.get())
    }

    @Test fun deeplinksSurviveLateListenerUntilAcknowledgement() {
        val links = PendingDeeplinks()
        links.enqueue("1", "teapod://import/a")
        links.enqueue("2", "teapod://import/b")
        assertEquals(listOf("1", "2"), links.snapshot().map { it["eventId"] })
        assertEquals(2, links.snapshot().size)
        links.acknowledge("1")
        links.enqueue("1", "teapod://import/a")
        assertEquals(listOf("2"), links.snapshot().map { it["eventId"] })
    }

    @Test fun prefixLookupExceptionRejectsClient() {
        val proxy = PrefixTcpProxy("127.0.0.1", 1, byteArrayOf(1)) { throw SecurityException() }
        proxy.start()
        try {
            Socket("127.0.0.1", proxy.localPort).use { it.soTimeout = 1000; assertEquals(-1, it.getInputStream().read()) }
        } finally { proxy.stop() }
    }

    @Test fun policyPreflightRejectsEmptyOnlyAndPrefixWithoutTun() {
        for ((mode, proxyOnly, prefix, expected) in listOf(
            listOf("onlySelected", false, null, "EMPTY_ALLOWED_APPS"),
            listOf("allExcept", true, "01", "PREFIX_REQUIRES_TUN"),
            listOf("unsupported", false, null, "INVALID_VPN_MODE"))) {
            try {
                AllowedApplications.validatePolicy(mode as String, proxyOnly as Boolean, prefix as String?, emptyList(), 10) { null }
                fail("Invalid policy passed preflight")
            } catch (e: ConnectionFailure) { assertEquals(expected, e.code) }
        }
    }

    @Test fun prefixPreservesHalfClosedUploadUntilResponseCompletes() {
        ServerSocket(0, 1, InetAddress.getLoopbackAddress()).use { upstream ->
            val received = CompletableFuture.supplyAsync {
                upstream.accept().use { socket ->
                    socket.soTimeout = 2000
                    val bytes = socket.getInputStream().readBytes()
                    socket.getOutputStream().write("response".toByteArray())
                    socket.shutdownOutput()
                    bytes
                }
            }
            val proxy = PrefixTcpProxy("127.0.0.1", upstream.localPort, byteArrayOf(1, 2)) { true }
            proxy.start()
            try {
                Socket("127.0.0.1", proxy.localPort).use { client ->
                    client.soTimeout = 2000
                    client.getOutputStream().write("request".toByteArray())
                    client.shutdownOutput()
                    assertEquals("response", String(client.getInputStream().readBytes()))
                }
                assertArrayEquals(byteArrayOf(1, 2) + "request".toByteArray(), received.get(2, TimeUnit.SECONDS))
            } finally { proxy.stop() }
        }
    }

    @Test fun prefixStopClosesIdleClientsAcrossOneHundredSessions() {
        repeat(100) {
            val accepted = CountDownLatch(1)
            val proxy = PrefixTcpProxy("127.0.0.1", 1, byteArrayOf(1)) { accepted.countDown(); true }
            proxy.start()
            Socket("127.0.0.1", proxy.localPort).use {
                assertTrue(accepted.await(1, TimeUnit.SECONDS))
                proxy.stop()
                it.soTimeout = 1000
                assertEquals(-1, it.getInputStream().read())
            }
        }
        assertFalse(Thread.getAllStackTraces().keys.any { it.isAlive && it.name.startsWith("prefix-") })
    }
}
