package com.teapodstream.teapodstream

import java.util.concurrent.Executors
import java.util.concurrent.Future
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/** The process-wide owner of operations on the singleton native core. */
internal class SessionCoordinator {
    private val executor = Executors.newSingleThreadExecutor { r -> Thread(r, "vpn-session").apply { isDaemon = true } }
    private val lock = Any()
    // A stop that outlived its deadline still owns the core; no start may run until it ends.
    private var pendingStop: Thread? = null
    private var onStopFinished: (() -> Unit)? = null
    @Volatile private var stopFailed = false
    /** A runtime stop is still draining after its deadline. */
    val stopPending: Boolean get() = synchronized(lock) { pendingStop != null }
    /** No new session may start: a stop is still draining or the core reported a failed stop. */
    val runtimeBlocked: Boolean get() = stopFailed || stopPending
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

    /**
     * Runs [stop] on a helper thread and waits at most [timeoutMs]. A stop that is
     * still running then keeps the runtime blocked but frees the session queue, so
     * disconnects and validations keep responding; [onFinished] is queued once it
     * ends. Returns true only when the stop completed in time without an error.
     */
    fun stopRuntime(timeoutMs: Long, onFinished: () -> Unit, stop: () -> Unit): Boolean {
        // Never call into the core while an earlier stop is still inside it.
        if (stopPending) return false
        var failure: Throwable? = null
        val worker = Thread {
            try { stop() } catch (t: Throwable) { failure = t; stopFailed = true }
            val finished = synchronized(lock) {
                pendingStop = null
                onStopFinished.also { onStopFinished = null }
            }
            if (finished != null) execute(finished)
        }.apply { isDaemon = true; name = "vpn-runtime-stop" }
        synchronized(lock) { pendingStop = worker }
        worker.start()
        worker.join(timeoutMs)
        synchronized(lock) {
            if (pendingStop === worker) {
                onStopFinished = onFinished
                return false
            }
        }
        return failure == null
    }
}
