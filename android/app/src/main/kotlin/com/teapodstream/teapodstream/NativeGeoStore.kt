package com.teapodstream.teapodstream

import android.content.Context
import android.util.AtomicFile
import java.io.File
import java.security.MessageDigest
import org.json.JSONObject

internal object NativeGeoStore {
    private fun hash(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(65536)
            while (true) { val n = input.read(buffer); if (n < 0) break; digest.update(buffer, 0, n) }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
    fun path(context: Context): String {
        val root = File(context.filesDir, "geo")
        val pointer = AtomicFile(File(root, "active.json"))
        val manifest = JSONObject(pointer.openRead().use { it.readBytes().toString(Charsets.UTF_8) })
        check(manifest.getInt("schema") == 1)
        val generation = manifest.getString("generation")
        check(Regex("generation-[0-9]+").matches(generation))
        val dir = File(root, generation)
        for (name in listOf("geoip.dat", "geosite.dat")) {
            val file = File(dir, name)
            val meta = manifest.getJSONObject("files").getJSONObject(name)
            check(file.length() > 0 && file.length() == meta.getLong("size") && hash(file) == meta.getString("sha256"))
        }
        return dir.absolutePath
    }
    @Synchronized fun prepare(context: Context): Boolean {
        try { path(context); return true } catch (_: Exception) {}
        // Never silently replace a damaged downloaded generation with different rules.
        if (File(context.filesDir, "geo/active.json").exists()) return false
        return try {
            val assetRoot = "flutter_assets/assets/binaries"
            val manifest = JSONObject(context.assets.open("$assetRoot/manifest.json").bufferedReader().use { it.readText() })
            val name = "generation-${System.currentTimeMillis()}"
            val root = File(context.filesDir, "geo").apply { mkdirs() }
            val dir = File(root, name).apply { mkdirs() }
            for (fileName in listOf("geoip.dat", "geosite.dat")) {
                val file = File(dir, fileName)
                context.assets.open("$assetRoot/$fileName").use { input -> file.outputStream().use { out -> input.copyTo(out); out.fd.sync() } }
                val expected = manifest.getJSONObject("files").getJSONObject(fileName)
                check(file.length() == expected.getLong("size") && hash(file) == expected.getString("sha256"))
            }
            manifest.put("schema", 1).put("generation", name)
            val pointer = AtomicFile(File(root, "active.json"))
            val stream = pointer.startWrite()
            try { stream.write(manifest.toString().toByteArray(Charsets.UTF_8)); pointer.finishWrite(stream) }
            catch (e: Exception) { pointer.failWrite(stream); throw e }
            true
        } catch (_: Exception) { false }
    }
}
