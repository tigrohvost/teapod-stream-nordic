package com.teapodstream.teapodstream

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

class HeartbeatMonitorTest {

    private fun reply(vararg chunks: ByteArray): ByteArrayInputStream =
        ByteArrayInputStream(chunks.fold(ByteArray(0)) { acc, c -> acc + c })

    private val connectReplyIpv4 =
        byteArrayOf(5, 0, 0, 1, 10, 0, 0, 1, 0, 80) // VER REP RSV ATYP=1 + 4 addr + 2 port

    private val http204 = "HTTP/1.1 204 No Content\r\n\r\n".toByteArray()

    @Test
    fun `probe succeeds without auth`() {
        val inp = reply(byteArrayOf(5, 0), connectReplyIpv4, http204)
        HeartbeatMonitor.probeSocks5(inp, ByteArrayOutputStream(), "", "")
    }

    @Test
    fun `probe succeeds with username password auth`() {
        val inp = reply(
            byteArrayOf(5, 2),       // server selects user/pass auth
            byteArrayOf(1, 0),       // auth OK
            connectReplyIpv4,
            http204,
        )
        val out = ByteArrayOutputStream()
        HeartbeatMonitor.probeSocks5(inp, out, "user", "secret")
        // greeting + auth frame (1 + len + user + len + pass) + connect must all be written
        assertTrue(out.toByteArray().size > 4 + 2 + "user".length + "secret".length)
    }

    @Test
    fun `truncated greeting reply throws instead of hanging`() {
        // Regression: EOF mid-reply used to make readFully spin forever on read() == -1.
        val inp = reply(byteArrayOf(5)) // one byte, then EOF
        try {
            HeartbeatMonitor.probeSocks5(inp, ByteArrayOutputStream(), "", "")
            fail("expected ProbeException")
        } catch (e: HeartbeatMonitor.ProbeException) {
            assertEquals("socks_greeting", e.stage)
        }
    }

    @Test
    fun `auth rejection reports socks_auth stage`() {
        val inp = reply(
            byteArrayOf(5, 2),
            byteArrayOf(1, 1), // auth failed
        )
        try {
            HeartbeatMonitor.probeSocks5(inp, ByteArrayOutputStream(), "user", "wrong")
            fail("expected ProbeException")
        } catch (e: HeartbeatMonitor.ProbeException) {
            assertEquals("socks_auth", e.stage)
        }
    }

    @Test
    fun `unsupported auth method reports socks_greeting stage`() {
        val inp = reply(byteArrayOf(5, 0xFF.toByte()))
        try {
            HeartbeatMonitor.probeSocks5(inp, ByteArrayOutputStream(), "", "")
            fail("expected ProbeException")
        } catch (e: HeartbeatMonitor.ProbeException) {
            assertEquals("socks_greeting", e.stage)
        }
    }

    @Test
    fun `socks connect refusal reports socks_connect stage`() {
        val inp = reply(
            byteArrayOf(5, 0),
            byteArrayOf(5, 5, 0, 1, 0, 0, 0, 0, 0, 0), // REP=5 connection refused
        )
        try {
            HeartbeatMonitor.probeSocks5(inp, ByteArrayOutputStream(), "", "")
            fail("expected ProbeException")
        } catch (e: HeartbeatMonitor.ProbeException) {
            assertEquals("socks_connect", e.stage)
        }
    }

    @Test
    fun `domain-type connect reply is consumed before http check`() {
        val domain = "example.org".toByteArray()
        val inp = reply(
            byteArrayOf(5, 0),
            byteArrayOf(5, 0, 0, 3, domain.size.toByte()) + domain + byteArrayOf(0, 80),
            http204,
        )
        HeartbeatMonitor.probeSocks5(inp, ByteArrayOutputStream(), "", "")
    }

    @Test
    fun `non-204 http response reports http_response stage`() {
        val inp = reply(
            byteArrayOf(5, 0),
            connectReplyIpv4,
            "HTTP/1.1 503 Service Unavailable\r\n\r\n".toByteArray(),
        )
        try {
            HeartbeatMonitor.probeSocks5(inp, ByteArrayOutputStream(), "", "")
            fail("expected ProbeException")
        } catch (e: HeartbeatMonitor.ProbeException) {
            assertEquals("http_response", e.stage)
        }
    }
}
