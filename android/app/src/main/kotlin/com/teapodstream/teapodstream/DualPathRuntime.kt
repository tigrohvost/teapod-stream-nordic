package com.teapodstream.teapodstream

import android.content.Context
import android.os.SystemClock
import android.provider.Settings
import java.security.MessageDigest
import org.json.JSONObject
import java.io.File
import java.net.InetAddress
import java.net.ServerSocket
import java.net.URI
import java.security.SecureRandom
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/** Child transports live in the VPN app UID, which the service excludes from TUN. */
internal class DualPathRuntime(private val context: Context, private val log: (String, String) -> Unit) {
    private val stopped = AtomicBoolean(false)
    private data class Child(val builder: ProcessBuilder, var process: Process,
        val native: Boolean, val retry: DualPathRetry = DualPathRetry(),
        var processGeneration: String,
        var startedAt: Long = SystemClock.elapsedRealtime())
    private val children = java.util.concurrent.CopyOnWriteArrayList<Child>()
    private val processLock = Any()
    private val outputLock = Any()
    private val directory = File(context.noBackupFilesDir, "dualpath-runtime")
    private var monitor: Thread? = null
    private var readyDescription = ""
    private val generation = secret()
    private var configHash = ""
    private val boot = "android-" + Settings.Global.getInt(context.contentResolver, Settings.Global.BOOT_COUNT, -1)
    private var unknownSince = 0L
    private var healthySince = 0L
    private fun invalidateStatus() {
        File(directory, "status.json").delete()
        readyDescription = ""
        log("warning", "Два сервера: проверка состояния")
    }

    private fun port(): Int = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
    private fun secret(): String = ByteArray(24).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
    private fun write(name: String, text: String): File = File(directory, name).also {
        it.writeText(text); it.setReadable(false, false); it.setWritable(false, false)
        it.setReadable(true, true); it.setWritable(true, true)
    }

    private fun drainOutput(process: Process, name: String) {
        Thread({
            try {
                process.inputStream.use { input ->
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = input.read(buffer)
                        if (count < 0) break
                        // Drain even when storage is full; otherwise stdout can
                        // deadlock a healthy child. Keep at most two 256 KiB logs.
                        synchronized(outputLock) {
                            try {
                                val file = File(directory, "$name.log")
                                if (file.length() + count > 262144) {
                                    val old = File(directory, "$name.previous.log")
                                    old.delete(); file.renameTo(old)
                                }
                                file.appendBytes(buffer.copyOf(count))
                            } catch (_: Exception) { /* Status lease independently expires on write failure. */ }
                        }
                    }
                }
            } catch (_: Exception) { /* Process terminated. */ }
        }, "dualpath-output").also { it.isDaemon = true; it.start() }
    }

    fun start(config: String): String {
        val s = DualPathConfig.spec(JSONObject(config)) ?: return config
        val naiveBinary = File(context.applicationInfo.nativeLibraryDir, "libteapod_naive.so")
        val dualBinary = File(context.applicationInfo.nativeLibraryDir, "libteapod_dualpath.so")
        if (!naiveBinary.canExecute() || !dualBinary.canExecute()) {
            throw ConnectionFailure("DUALPATH_UNAVAILABLE", "Двухсерверный режим недоступен в этой сборке")
        }
        directory.mkdirs()
        invalidateStatus()
        val user = secret(); val password = secret()
        val used = mutableSetOf<Int>()
        fun uniquePort(): Int { var p: Int; do { p = port() } while (!used.add(p)); return p }
        val naivePort = uniquePort(); val outerPort = uniquePort(); val socksPort = uniquePort()
        val fallbackPort = if (s.has("fallback")) uniquePort() else 0
        val ca = write("ca.pem", s.getString("ca"))
        val n = s.getJSONObject("naive")
        val proxy = URI("https", n.getString("username") + ":" + n.getString("password"), n.getString("serverName"), n.getInt("port"), null, null, null).toASCIIString()
        val naiveConfig = write("naive.json", JSONObject()
            .put("listen", "socks://$user:$password@127.0.0.1:$naivePort")
            .put("proxy", proxy)
            .put("host-resolver-rules", "MAP ${n.getString("serverName")} ${n.getString("address")}")
            .put("log", "").toString())
        val target = s.getJSONObject("collector")
        val address = target.getString("address")
        val targetAddress = (if (address.contains(":")) "[$address]" else address) + ":" + target.getInt("port")
        val nativeConfig = JSONObject().put("role", "proxy").put("listen", "127.0.0.1:$socksPort")
            .put("socks_user", user).put("socks_password", password)
            .put("proxy_user", user).put("proxy_password", password)
            .put("proxy_a", "127.0.0.1:$naivePort").put("proxy_b", "127.0.0.1:$outerPort")
            .put("target_a", targetAddress).put("target_b", targetAddress)
            .put("server_a", target.getString("serverName")).put("server_b", target.getString("serverName"))
            .put("ca", ca.absolutePath).put("token", s.getString("token"))
            .put("mode", s.optString("mode", "adaptive"))
            .put("runtime_generation", generation).put("network_epoch", generation).put("boot_id", boot)
            .put("status", File(directory, "status.json").absolutePath)
        if (fallbackPort != 0) nativeConfig.put("fallback_proxy", "127.0.0.1:$fallbackPort")
            .put("primary_ips",s.getJSONArray("expectedIps"))
            .put("fallback_ips",s.getJSONObject("fallback").getJSONArray("expectedIps"))
        val dualConfig = write("dualpath.json",nativeConfig.toString())
        configHash = MessageDigest.getInstance("SHA-256").digest(dualConfig.readBytes()).joinToString("") { "%02x".format(it) }
        try {
            launch(naiveBinary, listOf(naiveConfig.absolutePath), mapOf("SSL_CERT_FILE" to ca.absolutePath))
            launch(dualBinary, listOf("--config", dualConfig.absolutePath), mapOf("SSL_CERT_DIR" to
                "/apex/com.android.conscrypt/cacerts:/system/etc/security/cacerts"))
            monitor = Thread({
                while (!stopped.get()) {
                    try { Thread.sleep(2000) } catch (_: InterruptedException) { return@Thread }
                    val now = SystemClock.elapsedRealtime()
                    synchronized(processLock) {
                        if (stopped.get()) return@Thread
                        val native = children.firstOrNull { it.native }
                        val state = if (native != null && native.process.isAlive) {
                            try { DualPathHealth.read(File(directory, "status.json").readText(),
                                generation, configHash, boot, native.processGeneration, SystemClock.elapsedRealtime()) }
                            catch (_: Exception) { "unknown" }
                        } else "unknown"
                        if (state == "unknown") {
                            if (unknownSince == 0L) unknownSince = now
                        } else unknownSince = 0L
                        if (state == "ready") {
                            if (healthySince == 0L) healthySince = now
                            if (now - healthySince >= 60_000) children.forEach { it.retry.stable() }
                        } else healthySince = 0L
                        val description = when (state) {
                            "ready" -> "Два сервера: оба транспорта доступны"
                            "degraded" -> "Два сервера: работает один транспорт"
                            "unavailable" -> "Два сервера: нет связи со сборщиком"
                            "fallback" -> "Работает независимый резерв; новые соединения идут через него"
                            "blocked" -> "Нет проверенного выхода; новые соединения заблокированы"
                            else -> "Два сервера: состояние устарело или ещё не проверено"
                        }
                        if (description != readyDescription) {
                            readyDescription = description
                            log(if (state in listOf("ready","degraded","fallback")) "info" else "warning", description)
                        }
                        for (child in children) {
                            val stalled = child.native && unknownSince > 0 && now - unknownSince > 20_000 && now - child.startedAt > 30_000
                            if ((!child.process.isAlive || stalled) && child.retry.allowed(now)) {
                                val exitCode = if (!child.process.isAlive) child.process.exitValue() else null
                                if (child.process.isAlive) {
                                    child.process.destroy()
                                    if (!child.process.waitFor(1, TimeUnit.SECONDS)) child.process.destroyForcibly()
                                    if (!child.process.waitFor(2, TimeUnit.SECONDS)) continue
                                }
                                child.retry.failed(now, SecureRandom().nextInt(1001).toLong())
                                try {
                                    if (child.native) { invalidateStatus(); unknownSince = 0L }
                                    child.processGeneration = secret()
                                    child.builder.environment()["TEAPOD_PROCESS_GENERATION"] = child.processGeneration
                                    child.process = child.builder.start(); child.startedAt = now
                                    drainOutput(child.process, if (child.native) "dualpath" else "naive")
                                    log("warning", "Двухсерверный режим: компонент восстановлен, попытка ${child.retry.attempts}, причина ${exitCode ?: "нет прогресса"}")
                                } catch (_: Exception) {
                                    log("error", "Не удалось запустить компонент; повтор отложен")
                                }
                            }
                        }
                    }
                }
            }, "dualpath-monitor").also { it.isDaemon = true; it.start() }
            log("info", "Двухсерверный режим: Naive + XHTTP, ${s.optString("mode", "adaptive")}")
            return DualPathConfig.transform(config, socksPort, outerPort, user, password, fallbackPort)
        } catch (e: Exception) { stop(); throw e }
    }

    private fun launch(binary: File, args: List<String>, env: Map<String, String> = emptyMap()) {
        val builder = ProcessBuilder(listOf(binary.absolutePath) + args).directory(directory)
            .redirectErrorStream(true)
        builder.environment().putAll(env)
        val processGeneration = secret()
        builder.environment()["TEAPOD_PROCESS_GENERATION"] = processGeneration
        val process = builder.start(); children.add(Child(builder, process, binary.name.contains("dualpath"), processGeneration = processGeneration))
        drainOutput(process, if (binary.name.contains("dualpath")) "dualpath" else "naive")
        if (process.waitFor(150, TimeUnit.MILLISECONDS)) throw ConnectionFailure("DUALPATH_START_FAILED", "Не удалось запустить двухсерверный режим")
    }

    fun stop() {
        if (!stopped.compareAndSet(false, true)) return
        monitor?.interrupt()
        synchronized(processLock) {
            for (child in children.reversed()) {
                val process = child.process
                process.destroy(); if (!process.waitFor(1, TimeUnit.SECONDS)) process.destroyForcibly()
                process.waitFor(2, TimeUnit.SECONDS)
            }
            children.clear()
        }
        directory.listFiles()?.forEach { it.delete() }
    }
}
