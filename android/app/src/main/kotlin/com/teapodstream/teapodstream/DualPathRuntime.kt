package com.teapodstream.teapodstream

import android.content.Context
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
    private data class Child(val builder: ProcessBuilder, var process: Process)
    private val children = java.util.concurrent.CopyOnWriteArrayList<Child>()
    private val processLock = Any()
    private val directory = File(context.noBackupFilesDir, "dualpath-runtime")
    private var monitor: Thread? = null
    private var readyDescription = ""

    private fun port(): Int = ServerSocket(0, 1, InetAddress.getByName("127.0.0.1")).use { it.localPort }
    private fun secret(): String = ByteArray(24).also { SecureRandom().nextBytes(it) }.joinToString("") { "%02x".format(it) }
    private fun write(name: String, text: String): File = File(directory, name).also {
        it.writeText(text); it.setReadable(false, false); it.setWritable(false, false)
        it.setReadable(true, true); it.setWritable(true, true)
    }

    fun start(config: String): String {
        val s = DualPathConfig.spec(JSONObject(config)) ?: return config
        val naiveBinary = File(context.applicationInfo.nativeLibraryDir, "libteapod_naive.so")
        val dualBinary = File(context.applicationInfo.nativeLibraryDir, "libteapod_dualpath.so")
        if (!naiveBinary.canExecute() || !dualBinary.canExecute()) {
            throw ConnectionFailure("DUALPATH_UNAVAILABLE", "Двухсерверный режим недоступен в этой сборке")
        }
        directory.mkdirs()
        val user = secret(); val password = secret()
        val used = mutableSetOf<Int>()
        fun uniquePort(): Int { var p: Int; do { p = port() } while (!used.add(p)); return p }
        val naivePort = uniquePort(); val outerPort = uniquePort(); val socksPort = uniquePort()
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
        val dualConfig = write("dualpath.json", JSONObject().put("role", "proxy").put("listen", "127.0.0.1:$socksPort")
            .put("socks_user", user).put("socks_password", password)
            .put("proxy_user", user).put("proxy_password", password)
            .put("proxy_a", "127.0.0.1:$naivePort").put("proxy_b", "127.0.0.1:$outerPort")
            .put("target_a", targetAddress).put("target_b", targetAddress)
            .put("server_a", target.getString("serverName")).put("server_b", target.getString("serverName"))
            .put("ca", ca.absolutePath).put("token", s.getString("token"))
            .put("mode", s.optString("mode", "adaptive"))
            .put("status", File(directory, "status.json").absolutePath).toString())
        try {
            launch(naiveBinary, listOf(naiveConfig.absolutePath), mapOf("SSL_CERT_FILE" to ca.absolutePath))
            launch(dualBinary, listOf("--config", dualConfig.absolutePath))
            monitor = Thread({
                while (!stopped.get()) {
                    try { Thread.sleep(2000) } catch (_: InterruptedException) { return@Thread }
                    synchronized(processLock) {
                        if (!stopped.get()) for (child in children) {
                            if (!child.process.isAlive) {
                                try {
                                    child.process = child.builder.start()
                                    log("warning", "Двухсерверный режим: локальный транспорт перезапущен")
                                } catch (_: Exception) { log("error", "Не удалось перезапустить локальный транспорт") }
                            }
                        }
                    }
                    try {
                        val status = JSONObject(File(directory, "status.json").readText())
                        val a = status.optBoolean("ready_A"); val b = status.optBoolean("ready_B")
                        val description = "Naive: ${if (a) "доступен" else "ожидание"}; XHTTP: ${if (b) "доступен" else "ожидание"}"
                        if (description != readyDescription) { readyDescription = description; log(if (a || b) "info" else "warning", "Два сервера · $description") }
                    } catch (_: Exception) { /* First handshake has not completed. */ }
                }
            }, "dualpath-monitor").also { it.isDaemon = true; it.start() }
            log("info", "Двухсерверный режим: Naive + XHTTP, ${s.optString("mode", "adaptive")}")
            return DualPathConfig.transform(config, socksPort, outerPort, user, password)
        } catch (e: Exception) { stop(); throw e }
    }

    private fun launch(binary: File, args: List<String>, env: Map<String, String> = emptyMap()) {
        val builder = ProcessBuilder(listOf(binary.absolutePath) + args).directory(directory)
            .redirectErrorStream(true).redirectOutput(File(directory, binary.name + ".log"))
        builder.environment().putAll(env)
        val process = builder.start(); children.add(Child(builder, process))
        if (process.waitFor(150, TimeUnit.MILLISECONDS)) throw ConnectionFailure("DUALPATH_START_FAILED", "Не удалось запустить двухсерверный режим")
    }

    fun stop() {
        if (!stopped.compareAndSet(false, true)) return
        monitor?.interrupt()
        synchronized(processLock) {
            for (child in children.reversed()) {
                val process = child.process
                process.destroy(); if (!process.waitFor(1, TimeUnit.SECONDS)) process.destroyForcibly()
            }
            children.clear()
        }
        directory.listFiles()?.forEach { it.delete() }
    }
}
