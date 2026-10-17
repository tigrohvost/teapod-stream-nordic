package com.teapodstream.teapodstream

import android.util.AtomicFile
import java.io.File
import java.security.MessageDigest
import org.json.JSONObject

internal data class NativeSnapshot(val config: String, val params: ConnectionParams, val revision: Long)

internal class NativeSnapshotStore(private val dir: File) {
    private fun checksum(text: String) = MessageDigest.getInstance("SHA-256")
        .digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

    fun save(snapshot: NativeSnapshot, pending: Boolean) {
        val payload = JSONObject().put("schema", 1).put("revision", snapshot.revision)
            .put("config", snapshot.config).put("params", snapshot.params.toJson()).toString()
        val bytes = JSONObject().put("payload", payload).put("sha256", checksum(payload)).toString().toByteArray(Charsets.UTF_8)
        val file = AtomicFile(File(dir, if (pending) "connection_pending.json" else "connection_good.json"))
        val stream = file.startWrite()
        try { stream.write(bytes); file.finishWrite(stream) }
        catch (e: Exception) { file.failWrite(stream); throw e }
    }

    fun load(): NativeSnapshot? {
        val file = AtomicFile(File(dir, "connection_good.json"))
        if (!file.baseFile.exists() && !File(dir, "connection_good.json.bak").exists()) {
            // Legacy input is validated and promoted only after a successful start.
            val params = ConnectionParams.load(dir) ?: return null
            val config = File(dir, "xray_config.json")
            return if (config.exists()) NativeSnapshot(config.readText(), params, 0) else null
        }
        val envelope = JSONObject(file.openRead().use { it.readBytes().toString(Charsets.UTF_8) })
        val payload = envelope.getString("payload")
        check(checksum(payload) == envelope.getString("sha256")) { "SNAPSHOT_CORRUPT" }
        val json = JSONObject(payload)
        check(json.getInt("schema") == 1) { "SNAPSHOT_VERSION" }
        return NativeSnapshot(json.getString("config"), ConnectionParams.fromJson(json.getJSONObject("params")), json.getLong("revision"))
    }
}
