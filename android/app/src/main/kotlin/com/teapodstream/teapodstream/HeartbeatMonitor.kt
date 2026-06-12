package com.teapodstream.teapodstream

import java.io.BufferedReader
import java.io.InputStream
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger

/**
 * Watches an established VPN session and requests a reconnect when the tunnel dies.
 *
 * Every [INTERVAL_MS] it checks, in order:
 *  1. tun2socks process liveness (the SOCKS5 probe bypasses TUN, so it alone can't see a crash);
 *  2. gVisor connection-table leak ([TUN_CONN_LEAK_THRESHOLD]);
 *  3. end-to-end tunnel connectivity via a SOCKS5 CONNECT + HTTP 204 probe ([probeSocks5]);
 *  4. TUN-layer stall: probe passes but no data reaches the TUN interface ([TUN_STALL_TIMEOUT_MS]).
 *
 * All interaction with the service and the Go core goes through [Deps], so the
 * monitor can be unit-tested with fakes.
 */
internal class HeartbeatMonitor(private val deps: Deps) {

    /** Everything the monitor needs from the outside world. */
    interface Deps {
        /** True while the VPN session is up; the monitor loop exits when it turns false. */
        val running: Boolean
        /** False in proxy-only mode — TUN-level checks are skipped. */
        val tunModeActive: Boolean
        val socksPort: Int
        /** Atomic snapshot of SOCKS auth credentials (user to password). */
        fun socksAuth(): Pair<String, String>
        fun isTunRunning(): Boolean
        fun tunActiveConnections(): Long
        fun tunLastRxActivityMs(): Long
        fun tunStatsLine(): String
        fun hasDirectInternet(): Boolean
        fun requestReconnect()
        fun log(level: String, message: String)
    }

    /** Probe failure tagged with the protocol stage it died at. */
    class ProbeException(val stage: String, val detail: String?) :
        Exception("[$stage] ${detail ?: "unknown"}")

    companion object {
        const val INTERVAL_MS = 15_000L
        // After a reconnect xray establishes its outbound connection lazily. Probes run every
        // 15 s but failures are not counted until the first probe succeeds (warmup mode). This
        // self-adjusts to actual network speed instead of relying on a fixed timer. Hard ceiling:
        // if no probe succeeds within WARMUP_TIMEOUT_MS → something is genuinely broken.
        const val WARMUP_TIMEOUT_MS = 30_000L
        // If tun2socks has more than this many active proxy goroutines the gVisor TCP
        // state machine is leaking connections. Trigger a reconnect to reset it.
        const val TUN_CONN_LEAK_THRESHOLD = 200L
        // If no data has reached the TUN interface for this long while ≥2 connections
        // are active, tun2socks goroutines are stuck (proxy connections held alive by
        // keepalives but real data not flowing). SOCKS5 heartbeat won't catch this.
        const val TUN_STALL_TIMEOUT_MS = 120_000L
        const val MAX_FAILURES = 3
        const val PROBE_DEST_HOST = "cp.cloudflare.com"

        /**
         * SOCKS5 greeting + optional username/password auth + CONNECT to
         * [destHost]:80 + `GET /generate_204` — the full end-to-end tunnel probe.
         * Pure on streams: unit-testable without sockets.
         *
         * @throws ProbeException on any protocol-level failure, tagged with the stage.
         */
        fun probeSocks5(
            inp: InputStream,
            out: OutputStream,
            user: String,
            password: String,
            destHost: String = PROBE_DEST_HOST,
        ) {
            var stage = "socks_greeting"
            try {
                out.write(byteArrayOf(5, 2, 0, 2))
                val resp = readFully(inp, 2)
                if (resp[0] != 5.toByte()) throw Exception("SOCKS ver mismatch")

                when (resp[1].toInt()) {
                    0 -> {}
                    2 -> {
                        stage = "socks_auth"
                        if (user.isNotEmpty()) {
                            val u = user.toByteArray()
                            val p = password.toByteArray()
                            out.write(byteArrayOf(1, u.size.toByte()) + u + byteArrayOf(p.size.toByte()) + p)
                            val authResp = readFully(inp, 2)
                            if (authResp[1] != 0.toByte()) throw Exception("SOCKS auth failed")
                        }
                    }
                    else -> throw Exception("SOCKS auth not supported")
                }

                stage = "socks_connect"
                val destPort = 80
                val domainBytes = destHost.toByteArray()
                out.write(
                    byteArrayOf(5, 1, 0, 3, domainBytes.size.toByte()) +
                    domainBytes +
                    byteArrayOf((destPort shr 8).toByte(), destPort.toByte())
                )

                val reply = readFully(inp, 4)
                val replyRep = reply[1].toInt()
                val replyAtyp = reply[3].toInt()
                if (reply[0].toInt() != 5 || replyRep != 0) throw Exception("SOCKS connect failed: $replyRep")
                when (replyAtyp) {
                    1 -> readFully(inp, 6)
                    4 -> readFully(inp, 18)
                    3 -> {
                        val len = inp.read()
                        if (len < 0) throw Exception("SOCKS reply truncated (no domain len)")
                        readFully(inp, len + 2)
                    }
                }

                stage = "http_request"
                val request = "GET /generate_204 HTTP/1.1\r\nHost: $destHost\r\nConnection: close\r\n\r\n"
                out.write(request.toByteArray())
                out.flush()

                stage = "http_response"
                val reader = BufferedReader(InputStreamReader(inp))
                val line = reader.readLine()
                if (line == null || !line.contains("204")) {
                    throw Exception("Invalid HTTP response: $line")
                }
            } catch (e: ProbeException) {
                throw e
            } catch (e: Exception) {
                throw ProbeException(stage, e.message)
            }
        }

        private fun readFully(inp: InputStream, size: Int): ByteArray {
            val buf = ByteArray(size)
            var read = 0
            while (read < size) {
                val n = inp.read(buf, read, size - read)
                if (n < 0) throw Exception("SOCKS reply truncated (EOF at $read/$size)")
                read += n
            }
            return buf
        }
    }

    private var thread: Thread? = null
    private val failures = AtomicInteger(0)

    fun start(isReconnect: Boolean = false) {
        deps.log("info", "startHeartbeat (isReconnect=$isReconnect)")
        thread?.interrupt()
        failures.set(0)
        thread = Thread {
            // In reconnect mode: probes run every 15 s but failures are ignored until the
            // first probe succeeds (warmup). This self-adjusts to actual network conditions —
            // no magic fixed delay. Hard ceiling: warmupDeadline prevents staying in warmup
            // forever if the server is genuinely unreachable.
            var warmupDone = !isReconnect
            var warmupDeadline = 0L  // set on first probe iteration, not at thread start
            // Counts consecutive skips due to no physical internet. When internet returns
            // after a long absence the tunnel session is stale regardless of protocol, so
            // the first probe failure should immediately trigger a reconnect.
            var noInternetStreak = 0
            var successCount = 0
            var lastStallWarnAt = 0L

            while (!Thread.currentThread().isInterrupted && deps.running) {
                try {
                    Thread.sleep(INTERVAL_MS)
                    if (!deps.running) break
                    // Start deadline from first actual probe — not from thread creation,
                    // which may be long before xray is ready after a slow reconnect.
                    if (!warmupDone && warmupDeadline == 0L) {
                        warmupDeadline = System.currentTimeMillis() + WARMUP_TIMEOUT_MS
                    }
                    val port = deps.socksPort
                    if (port <= 0) continue

                    // Check tun2socks is alive before testing SOCKS5 connectivity.
                    // The SOCKS5 probe bypasses TUN entirely, so it passes even if tun2socks
                    // has crashed or its goroutines are deadlocked.
                    // Skip in proxy-only mode: tun2socks is intentionally not started.
                    if (deps.tunModeActive && !deps.isTunRunning()) {
                        deps.log("warning", "tun2socks not running, reconnecting")
                        deps.requestReconnect()
                        break
                    }

                    // Detect gVisor connection table leak: if the number of active proxy
                    // goroutines is abnormally high the TCP state machine is accumulating
                    // stale entries (TIME_WAIT / CLOSE_WAIT). Reconnect to reset gVisor.
                    if (deps.tunModeActive) {
                        val activeConns = deps.tunActiveConnections()
                        if (activeConns > TUN_CONN_LEAK_THRESHOLD) {
                            deps.log("warning", "gVisor connection leak detected (activeConns=$activeConns), reconnecting")
                            deps.requestReconnect()
                            break
                        }
                    }

                    probeOverSocket(port)
                    warmupDone = true
                    failures.set(0)
                    noInternetStreak = 0
                    successCount++
                    if (successCount % 5 == 0) {
                        val activeConns = if (deps.tunModeActive) deps.tunActiveConnections() else 0L
                        deps.log("info", "Heartbeat alive (${successCount} ok, tun=${deps.isTunRunning()}, conns=$activeConns)")
                    }
                    // Log detailed tunnel stats every ~1 minute for diagnostics.
                    // tunStatsLine() returns a Go string → log() routes it to
                    // vpn_log.txt + Flutter EventChannel (not only logcat).
                    if (deps.tunModeActive && successCount % 4 == 0) {
                        val stats = deps.tunStatsLine()
                        if (stats.isNotEmpty()) {
                            val lastRx = deps.tunLastRxActivityMs()
                            val lastRxSec = if (lastRx > 0) (System.currentTimeMillis() - lastRx) / 1000 else -1
                            deps.log("debug", "tun stats: $stats lastRxSec=$lastRxSec")
                        }
                    }
                    // Detect TUN-layer stall: SOCKS5 heartbeat bypasses tun2socks entirely,
                    // so it passes even when proxy goroutines are alive but no data reaches
                    // the TUN interface (e.g. xray connections half-open, held by keepalives).
                    // tunLastRxActivityMs() is updated on every TUN write in tun2socks.
                    if (deps.tunModeActive) {
                        val lastRx = deps.tunLastRxActivityMs()
                        if (lastRx > 0) {
                            val now = System.currentTimeMillis()
                            val idleSec = (now - lastRx) / 1000
                            val activeConns by lazy { deps.tunActiveConnections() }
                            when {
                                idleSec >= TUN_STALL_TIMEOUT_MS / 1000 && activeConns >= 2 -> {
                                    deps.log("warning", "TUN stall: no data for ${idleSec}s (conns=$activeConns), reconnecting")
                                    deps.requestReconnect()
                                    break
                                }
                                idleSec >= 60 && activeConns >= 2 && now - lastStallWarnAt >= 60_000 -> {
                                    deps.log("warning", "TUN rx idle for ${idleSec}s (conns=$activeConns)")
                                    lastStallWarnAt = now
                                }
                            }
                        }
                    }
                } catch (_: InterruptedException) {
                    break
                } catch (e: Exception) {
                    // If the physical network is down it's not xray's fault — skip failure
                    // count to prevent useless reconnect cycles during WiFi→LTE transitions.
                    // network_changed will trigger a reconnect once the new network is ready.
                    if (!deps.hasDirectInternet()) {
                        noInternetStreak++
                        deps.log("debug", "Heartbeat skipped: no direct internet (streak=$noInternetStreak)")
                        continue
                    }
                    // Network just returned after a long absence — the tunnel session is
                    // guaranteed stale (QUIC/TCP connection to the server was dead while we
                    // had no route). Skip the normal 3-failure wait and reconnect immediately.
                    if (noInternetStreak >= 3) {
                        val absenceSec = noInternetStreak * (INTERVAL_MS / 1000)
                        noInternetStreak = 0
                        deps.log("warning", "Tunnel stale after ${absenceSec}s network absence, reconnecting")
                        deps.requestReconnect()
                        break
                    }
                    noInternetStreak = 0
                    if (!warmupDone) {
                        if (warmupDeadline == 0L || System.currentTimeMillis() < warmupDeadline) {
                            deps.log("debug", "Heartbeat warmup probe failed: ${e.message}")
                            continue
                        }
                        deps.log("warning", "Heartbeat warmup timed out (30 s), reconnecting")
                        deps.requestReconnect()
                        break
                    }
                    val failureCount = failures.incrementAndGet()
                    deps.log("warning", "Heartbeat failed ($failureCount): ${e.message}")
                    if (failureCount >= MAX_FAILURES) {
                        deps.log("warning", "Heartbeat failed $failureCount times, reconnecting")
                        deps.requestReconnect()
                        break
                    }
                    var immediateRetries = 0
                    while (immediateRetries < 2 && !Thread.currentThread().isInterrupted) {
                        try {
                            Thread.sleep(3000)
                            probeOverSocket(deps.socksPort)
                            warmupDone = true
                            failures.set(0)
                            break
                        } catch (_: InterruptedException) {
                            break
                        } catch (_: Exception) {
                            immediateRetries++
                        }
                    }
                    if (failures.get() >= MAX_FAILURES) {
                        deps.log("warning", "Heartbeat retries exhausted, reconnecting")
                        deps.requestReconnect()
                        break
                    }
                }
            }
        }.also { it.isDaemon = true; it.start() }
    }

    fun stop() {
        if (thread != null) deps.log("info", "stopHeartbeat: interrupting heartbeat thread")
        thread?.interrupt()
        thread = null
        failures.set(0)
    }

    /** Connects to the local SOCKS proxy and runs [probeSocks5] over the socket. */
    private fun probeOverSocket(port: Int) {
        val socket = Socket()
        try {
            socket.soTimeout = 10000
            socket.connect(InetSocketAddress("127.0.0.1", port), 10000)
            val (user, password) = deps.socksAuth()
            probeSocks5(socket.getInputStream(), socket.getOutputStream(), user, password)
            failures.set(0)
            deps.log("debug", "Heartbeat OK")
        } catch (e: ProbeException) {
            deps.log("warning", "Heartbeat check failed at [${e.stage}]: ${e.detail}")
            throw e
        } catch (e: Exception) {
            deps.log("warning", "Heartbeat check failed at [tcp_connect]: ${e.message}")
            throw e
        } finally {
            socket.close()
        }
    }
}
