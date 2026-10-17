package com.teapodstream.teapodstream

import java.io.InputStream
import java.io.OutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger

/**
 * Watches an established VPN session and requests a reconnect when the tunnel dies.
 *
 * Every [INTERVAL_MS] it checks, in order:
 *  1. tun2socks process liveness (the SOCKS5 probe bypasses TUN, so it alone can't see a crash);
 *  2. independent HTTP 204 destinations through SOCKS5;
 *  3. end-to-end tunnel connectivity via a SOCKS5 CONNECT + HTTP 204 probe ([probeSocks5]);
 *  4. TUN-layer stall: probe passes but no data reaches the TUN interface ([TUN_STALL_TIMEOUT_MS]).
 *
 * All interaction with the service and the Go core goes through [Deps], so the
 * monitor can be unit-tested with fakes.
 */
internal class HeartbeatMonitor(
    private val deps: Deps,
    // Timings are injectable only so tests can run the loop in milliseconds.
    private val intervalMs: Long = INTERVAL_MS,
    private val warmupTimeoutMs: Long = WARMUP_TIMEOUT_MS,
    private val retryDelayMs: Long = RETRY_DELAY_MS,
) {

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
        fun hasUnderlyingNetwork(): Boolean = true
        /**
         * @param afterProbeFailure true when the tunnel was declared dead by failing
         *   end-to-end probes (as opposed to a local tun2socks problem); the service
         *   counts these to back off while the server stays unreachable.
         */
        fun requestReconnect(afterProbeFailure: Boolean = false)
        /** Called after every successful end-to-end probe. */
        fun onProbeSuccess()
        /**
         * How long a probe-failure reconnect is deferred, keeping the current session
         * up and probing meanwhile. 0 = reconnect right away.
         */
        fun reconnectBackoffMs(): Long
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
        // Pause before each of the two quick re-probes after a single failure.
        const val RETRY_DELAY_MS = 3_000L
        // If no data has reached the TUN interface for this long while ≥2 connections
        // are active, tun2socks goroutines are stuck. lastRx moves on any TUN write
        // (ACKs included), so a quiet TUN usually just means idle apps — the timeout
        // is kept above xray's connIdle (XrayDefaults.connIdleTimeout, 300 s): by then
        // xray has closed genuinely idle connections, and whatever is still counted
        // is a stuck entry rather than an idle app.
        const val TUN_STALL_TIMEOUT_MS = 360_000L
        // Screen-on check: after this much TUN silence the session is probed once
        // end-to-end (and only reconnected if the probe fails).
        const val WAKE_PROBE_IDLE_MS = 120_000L
        const val MAX_FAILURES = 3
        const val PROBE_DEST_HOST = "cp.cloudflare.com"
        private val PROBE_HOSTS = arrayOf(PROBE_DEST_HOST, "connectivitycheck.gstatic.com")
        private const val RECONNECT_BACKOFF_BASE_MS = 15_000L
        private const val RECONNECT_BACKOFF_MAX_MS = 300_000L

        /**
         * Delay before the next probe-failure reconnect, given how many such reconnects
         * in a row never got a single successful probe: 0, 15 s, 30 s, 60 s … capped at
         * 5 min. Without it an unreachable server made the monitor rebuild the tunnel
         * every ~60 s forever.
         */
        fun backoffForStreak(streak: Int): Long {
            if (streak <= 0) return 0L
            val shift = (streak - 1).coerceAtMost(5)
            return (RECONNECT_BACKOFF_BASE_MS shl shift).coerceAtMost(RECONNECT_BACKOFF_MAX_MS)
        }

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
                        if (user.isEmpty()) throw Exception("SOCKS credentials required")
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
                    else -> throw Exception("Unsupported SOCKS address type")
                }

                stage = "http_request"
                val request = "GET /generate_204 HTTP/1.1\r\nHost: $destHost\r\nConnection: close\r\n\r\n"
                out.write(request.toByteArray())
                out.flush()

                stage = "http_response"
                val status = StringBuilder()
                while (status.length < 4096) {
                    val byte = inp.read()
                    if (byte == -1 || byte == 10) break
                    status.append(byte.toChar())
                }
                if (!Regex("^HTTP/1\\.[01] 204(?:[ \\r]|$)").containsMatchIn(status.toString())) {
                    throw Exception("Invalid HTTP status")
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
    private val generation = AtomicInteger(0)
    private val activeSockets = java.util.concurrent.ConcurrentHashMap.newKeySet<Socket>()
    private val destination = AtomicInteger(0)
    private fun monotonicMs() = System.nanoTime() / 1_000_000
    private val failures = AtomicInteger(0)

    fun start(isReconnect: Boolean = false) {
        deps.log("info", "startHeartbeat (isReconnect=$isReconnect)")
        stop()
        val owner = generation.incrementAndGet()
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
            // When a probe-failure reconnect is being deferred (backoff), the time it
            // becomes due. Cleared by any successful probe.
            var reconnectDueAt = 0L

            // Returns true when the reconnect was requested and the loop must exit;
            // false while it is deferred and the session is kept up.
            fun reconnectAfterProbeFailure(reason: String): Boolean {
                val backoff = deps.reconnectBackoffMs()
                val now = monotonicMs()
                if (backoff <= 0L || (reconnectDueAt != 0L && now >= reconnectDueAt)) {
                    deps.log("warning", reason)
                    if (owner == generation.get() && !Thread.currentThread().isInterrupted) deps.requestReconnect(afterProbeFailure = true)
                    return true
                }
                if (reconnectDueAt == 0L) {
                    reconnectDueAt = now + backoff
                    deps.log("warning", "$reason; server unreachable since the last reconnect, next attempt in ${backoff / 1000}s")
                }
                return false
            }

            while (!Thread.currentThread().isInterrupted && deps.running && owner == generation.get()) {
                try {
                    Thread.sleep(intervalMs)
                    if (!deps.running) break
                    // Start deadline from first actual probe — not from thread creation,
                    // which may be long before xray is ready after a slow reconnect.
                    if (!warmupDone && warmupDeadline == 0L) {
                        warmupDeadline = monotonicMs() + warmupTimeoutMs
                    }
                    val port = deps.socksPort
                    if (port <= 0) continue

                    // Check tun2socks is alive before testing SOCKS5 connectivity.
                    // The SOCKS5 probe bypasses TUN entirely, so it passes even if tun2socks
                    // has crashed or its goroutines are deadlocked.
                    // Skip in proxy-only mode: tun2socks is intentionally not started.
                    if (deps.tunModeActive && !deps.isTunRunning()) {
                        deps.log("warning", "tun2socks not running, reconnecting")
                        if (reconnectAfterProbeFailure("Local TUN runtime stopped")) break
                        continue
                    }

                    probeOverSocket(port, owner)
                    warmupDone = true
                    failures.set(0)
                    noInternetStreak = 0
                    reconnectDueAt = 0L
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
                                    deps.log("debug", "TUN idle for ${idleSec}s (conns=$activeConns); probe passes, retaining session")
                                    // Idle connection count is not proof of a failed tunnel.
                                    // The independent probe just succeeded; retain this session.
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
                    if (Thread.currentThread().isInterrupted || owner != generation.get()) break
                    if (!deps.hasUnderlyingNetwork()) {
                        noInternetStreak++
                        deps.log("debug", "Underlying network unavailable (streak=$noInternetStreak)")
                        if (!warmupDone && monotonicMs() >= warmupDeadline) {
                            if (reconnectAfterProbeFailure("Underlying network warmup deadline expired")) break
                        }
                        continue
                    }
                    // Failure of an external probe means unknown/partial reachability,
                    // not proof of an absent network. It must not reset the deadline.
                    if (!deps.hasDirectInternet()) deps.log("debug", "Direct reachability unknown; checking VPN failure budget")
                    noInternetStreak = 0
                    if (!warmupDone) {
                        if (warmupDeadline == 0L || monotonicMs() < warmupDeadline) {
                            deps.log("debug", "Heartbeat warmup probe failed: ${e.message}")
                            continue
                        }
                        if (reconnectAfterProbeFailure("Heartbeat warmup timed out (30 s), reconnecting")) break
                        continue
                    }
                    val failureCount = failures.incrementAndGet()
                    deps.log("warning", "Heartbeat failed ($failureCount): ${e.message}")
                    if (failureCount >= MAX_FAILURES) {
                        // Probe rides through the routing balancer and can land on a dead
                        // detour while real traffic flows fine — a false positive. If the
                        // TUN saw downstream data within the last probe interval, keep the
                        // session and just reset the counter.
                        if (isTunRxFresh()) {
                            deps.log("warning", "Heartbeat failing but TUN traffic is alive, skipping reconnect")
                            failures.set(0)
                            continue
                        }
                        if (reconnectAfterProbeFailure("Heartbeat failed $failureCount times, reconnecting")) break
                        continue
                    }
                    var immediateRetries = 0
                    while (immediateRetries < 2 && owner == generation.get() && !Thread.currentThread().isInterrupted) {
                        try {
                            Thread.sleep(retryDelayMs)
                            probeOverSocket(deps.socksPort, owner)
                            warmupDone = true
                            failures.set(0)
                            reconnectDueAt = 0L
                            break
                        } catch (_: InterruptedException) {
                            break
                        } catch (_: Exception) {
                            immediateRetries++
                        }
                    }
                    if (failures.get() >= MAX_FAILURES) {
                        if (isTunRxFresh()) {
                            deps.log("warning", "Heartbeat failing but TUN traffic is alive, skipping reconnect")
                            failures.set(0)
                            continue
                        }
                        if (reconnectAfterProbeFailure("Heartbeat retries exhausted, reconnecting")) break
                    }
                }
            }
        }.also { it.isDaemon = true; it.start() }
    }

    // True when tun2socks wrote data to the TUN within the last heartbeat interval —
    // the tunnel is demonstrably passing traffic even if the probe itself fails.
    private fun isTunRxFresh(): Boolean {
        if (!deps.tunModeActive) return false
        val lastRx = deps.tunLastRxActivityMs()
        return lastRx > 0 && System.currentTimeMillis() - lastRx < intervalMs
    }

    fun stop() {
        if (thread != null) deps.log("info", "stopHeartbeat: interrupting heartbeat thread")
        generation.incrementAndGet()
        thread?.interrupt()
        try { activeSockets.toList().forEach { it.close() } } catch (_: Exception) {}
        thread?.let { if (it !== Thread.currentThread()) it.join(1000) }
        thread = null
        failures.set(0)
    }

    /**
     * One end-to-end probe outside the loop (e.g. when the screen turns on).
     * Blocks for up to the socket timeout — never call it on the main thread.
     */
    fun probeOnce(): Boolean {
        val port = deps.socksPort
        if (port <= 0) return false
        return try {
            probeOverSocket(port)
            true
        } catch (_: Exception) {
            false
        }
    }

    /** Connects to the local SOCKS proxy and runs [probeSocks5] over the socket. */
    private fun probeOverSocket(port: Int, owner: Int = generation.get()) {
        if (owner != generation.get()) throw InterruptedException()
        val socket = Socket()
        activeSockets.add(socket)
        val deadline = java.util.Timer("heartbeat-deadline", true)
        deadline.schedule(object : java.util.TimerTask() { override fun run() { try { socket.close() } catch (_: Exception) {} } }, 10_000)
        try {
            if (owner != generation.get()) throw InterruptedException()
            socket.soTimeout = 10000
            socket.connect(InetSocketAddress("127.0.0.1", port), 10000)
            val (user, password) = deps.socksAuth()
            probeSocks5(socket.getInputStream(), socket.getOutputStream(), user, password, PROBE_HOSTS[Math.floorMod(destination.getAndIncrement(), PROBE_HOSTS.size)])
            if (owner != generation.get() || Thread.currentThread().isInterrupted) throw InterruptedException()
            failures.set(0)
            deps.onProbeSuccess()
            deps.log("debug", "Heartbeat OK")
        } catch (e: ProbeException) {
            deps.log("warning", "Heartbeat check failed at [${e.stage}]: ${e.detail}")
            throw e
        } catch (e: Exception) {
            deps.log("warning", "Heartbeat check failed at [tcp_connect]: ${e.message}")
            throw e
        } finally {
            deadline.cancel()
            activeSockets.remove(socket)
            socket.close()
        }
    }
}
