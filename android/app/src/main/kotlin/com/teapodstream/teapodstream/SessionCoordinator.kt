package com.teapodstream.teapodstream

import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** The process-wide owner of operations on the singleton native core. */
internal class SessionCoordinator {
    private val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "vpn-session").apply { isDaemon = true } }
    @Volatile var runtimeBlocked = false
        private set
    private val generation = AtomicLong(0)
    private val reconnectPending = AtomicBoolean(false)
    fun invalidate(): Long = generation.incrementAndGet()
    fun isCurrent(id: Long): Boolean = generation.get() == id
    fun execute(command: () -> Unit): Future<*> = executor.submit(command)
    fun reconnect(id: Long, command: () -> Unit) {
        if (!isCurrent(id) || !reconnectPending.compareAndSet(false, true)) return
        execute {
            try { if (isCurrent(id)) command() } finally { reconnectPending.set(false) }
        }
    }

    /** A deadline reports a blocked stop; ownership is retained until it finishes. */
    fun stopAndAwait(timeoutMs: Long, onBlocked: () -> Unit, stop: () -> Unit) {
        var failure: Throwable? = null
        val worker = Thread { try { stop() } catch (t: Throwable) { failure = t } }
            .apply { isDaemon = true; name = "vpn-runtime-stop"; start() }
        worker.join(timeoutMs)
        if (worker.isAlive) { onBlocked(); worker.join() }
        failure?.let { runtimeBlocked = true; onBlocked(); throw it }
    }
}
