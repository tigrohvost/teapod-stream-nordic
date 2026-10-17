package com.teapodstream.teapodstream

import android.content.Context
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.nio.charset.CodingErrorAction
import java.security.DigestInputStream
import java.security.MessageDigest
import org.json.JSONObject

/**
 * Active geodata pair under `filesDir/geo`: `active.json` names a verified
 * `generation-*` directory and (optionally) its predecessor. Dart's
 * GeoDataRepository writes the same layout when it downloads an update, so a
 * generation is never modified after its pointer is committed.
 */
internal class GeoStore(
    private val filesDir: File,
    private val openBundled: (String) -> InputStream,
    private val legacyUpdatedAtMs: () -> Long? = { null },
    private val hasher: (File) -> String = { sha256Hex(it) },
) {
    private val root = File(filesDir, "geo")
    private val pointer = File(root, "active.json")
    // path|size|mtime of files whose hash already matched a manifest in this process:
    // a connect or validation must not re-hash ~28 MB every time.
    private val verified = HashSet<String>()

    /** Directory with a verified pair for the core; repairs or installs it first if needed. */
    @Synchronized fun activePath(log: (String, String) -> Unit): String {
        val active = readManifest(pointer)
        if (active != null && verify(active)) {
            removeStale(active)
            return dir(active).path
        }
        if (active == null && !pointer.exists()) {
            adoptLegacy(log)?.let { return it }
            return installBundled(log, restoredFrom = null)
        }
        val damaged = active?.optString("generation") ?: "active.json"
        val previous = active?.optString("previous").orEmpty()
        val fallback = if (GENERATION.matches(previous)) readManifest(File(File(root, previous), "manifest.json")) else null
        if (fallback != null && fallback.getString("generation") == previous && verify(fallback)) {
            log("warning", "Geodata $damaged failed verification; restored the previous pair $previous")
            activate(JSONObject(fallback.toString()).put("restoredFrom", damaged).also { it.remove("previous") })
            removeStale(fallback)
            return dir(fallback).path
        }
        log("warning", "Geodata $damaged failed verification and no previous pair is intact; using the bundled pair")
        return installBundled(log, restoredFrom = damaged)
    }

    private fun dir(manifest: JSONObject) = File(root, manifest.getString("generation"))

    private fun key(file: File) = "${file.path}|${file.length()}|${file.lastModified()}"

    private fun readManifest(file: File): JSONObject? = try {
        val json = JSONObject(file.readText())
        val files = json.getJSONObject("files")
        if (json.getInt("schema") != 1 || !GENERATION.matches(json.getString("generation"))) null
        else if (NAMES.all { files.getJSONObject(it).getLong("size") > 0 && files.getJSONObject(it).getString("sha256").isNotEmpty() }) json
        else null
    } catch (_: Exception) { null }

    private fun verify(manifest: JSONObject): Boolean = NAMES.all { name ->
        val file = File(dir(manifest), name)
        val meta = manifest.getJSONObject("files").getJSONObject(name)
        if (!file.isFile || file.length() != meta.getLong("size")) return@all false
        val key = key(file)
        if (key in verified) return@all true
        (hasher(file) == meta.getString("sha256")).also { if (it) verified.add(key) }
    }

    private fun newGeneration(): File {
        root.mkdirs()
        var stamp = System.currentTimeMillis()
        while (File(root, "generation-$stamp").exists()) stamp++
        return File(root, "generation-$stamp").apply { mkdirs() }
    }

    /** Commits [manifest] as the active pair with one atomic rename. */
    private fun activate(manifest: JSONObject) {
        val generation = manifest.getString("generation")
        val own = File(File(root, generation), "manifest.json")
        if (!own.exists()) writeSynced(own, manifest.toString())
        val staging = File(root, "active-$generation.tmp")
        writeSynced(staging, manifest.toString())
        if (!staging.renameTo(pointer)) {
            staging.delete()
            throw IOException("Failed to switch the active geodata pointer")
        }
    }

    private fun writeSynced(file: File, text: String) {
        file.outputStream().use { it.write(text.toByteArray(Charsets.UTF_8)); it.fd.sync() }
    }

    private fun copySynced(input: InputStream, target: File) {
        input.use { i -> target.outputStream().use { o -> i.copyTo(o); o.fd.sync() } }
    }

    /**
     * v1.6.6 kept the pair directly in filesDir. A pair the user downloaded there
     * (possibly from a custom source, recorded by geo_last_updated) is kept; an
     * untouched copy of the old bundled pair is replaced by the current one.
     */
    private fun adoptLegacy(log: (String, String) -> Unit): String? {
        val legacy = NAMES.map { File(filesDir, it) }
        val downloadedAt = legacyUpdatedAtMs()
        if (downloadedAt == null || !legacy.all { it.isFile }) return null
        val target = newGeneration()
        return try {
            val updatedAt = java.time.Instant.ofEpochMilli(downloadedAt).toString()
            val files = JSONObject()
            for (source in legacy) {
                val copy = File(target, source.name)
                copySynced(source.inputStream(), copy)
                val digest = MessageDigest.getInstance("SHA-256")
                DigestInputStream(copy.inputStream(), digest).use { GeoDatValidator.validate(it, source.name) }
                verified.add(key(copy))
                files.put(source.name, JSONObject().put("source", "legacy").put("version", "legacy")
                    .put("verifiedAt", updatedAt).put("size", copy.length()).put("sha256", hex(digest.digest())))
            }
            activate(JSONObject().put("schema", 1).put("generation", target.name).put("verifiedAt", updatedAt).put("files", files))
            legacy.forEach { it.delete() }
            log("info", "Geodata from the previous app version kept as ${target.name}")
            target.path
        } catch (e: Exception) {
            target.deleteRecursively()
            log("warning", "Geodata from the previous app version is invalid (${e.message}); using the bundled pair")
            null
        }
    }

    private fun installBundled(log: (String, String) -> Unit, restoredFrom: String?): String {
        val target = newGeneration()
        try {
            val bundled = JSONObject(openBundled("manifest.json").bufferedReader().use { it.readText() })
            for (name in NAMES) {
                val expected = bundled.getJSONObject("files").getJSONObject(name)
                val copy = File(target, name)
                copySynced(openBundled(name), copy)
                if (copy.length() != expected.getLong("size") || hasher(copy) != expected.getString("sha256")) {
                    throw IOException("Bundled $name does not match its manifest")
                }
                verified.add(key(copy))
            }
            val manifest = JSONObject(bundled.toString()).put("schema", 1).put("generation", target.name)
            if (restoredFrom != null) manifest.put("restoredFrom", restoredFrom)
            activate(manifest)
            NAMES.forEach { File(filesDir, it).delete() }
            removeStale(manifest)
            log("info", "Bundled geodata installed as ${target.name}")
            return target.path
        } catch (e: Exception) {
            target.deleteRecursively()
            throw ConnectionFailure("GEODATA_UNAVAILABLE", "Геобазы недоступны: ${e.message}")
        }
    }

    /**
     * Keeps the active pair and its predecessor. Other generations and pointer
     * leftovers go once older than [STALE_MS], so a download still staging (Dart)
     * is never touched; v1.6.6 copies left by an interrupted migration go too.
     */
    private fun removeStale(active: JSONObject) {
        val keep = setOf(active.getString("generation"), active.optString("previous"))
        val cutoff = System.currentTimeMillis() - STALE_MS
        root.listFiles()?.forEach { entry ->
            if (entry.name in keep || entry.lastModified() > cutoff) return@forEach
            if (entry.isDirectory && GENERATION.matches(entry.name)) entry.deleteRecursively()
            else if (entry.isFile && entry.name.startsWith("active-") && entry.name.endsWith(".tmp")) entry.delete()
        }
        NAMES.forEach { File(filesDir, it).delete() }
    }

    companion object {
        val NAMES = listOf("geoip.dat", "geosite.dat")
        private val GENERATION = Regex("generation-[0-9]+")
        private const val STALE_MS = 60 * 60 * 1000L

        fun sha256Hex(file: File): String {
            val digest = MessageDigest.getInstance("SHA-256")
            DigestInputStream(file.inputStream(), digest).use { input ->
                val buffer = ByteArray(65536)
                while (input.read(buffer) >= 0) { }
            }
            return hex(digest.digest())
        }

        private fun hex(bytes: ByteArray) = bytes.joinToString("") { "%02x".format(it) }
    }
}

/** Streaming port of GeoDataRepository.validateDat (Dart): rejects HTML, truncation and empty data. */
internal object GeoDatValidator {
    private const val MAX_ENTRY_BYTES = 64 * 1024 * 1024

    fun validate(input: InputStream, kind: String) {
        val stream = java.io.BufferedInputStream(input, 65536)
        var count = 0
        while (true) {
            val key = readVarint(stream, allowEof = true) ?: break
            if (key ushr 3 != 1L || key and 7 != 2L) throw IllegalArgumentException("Unexpected top-level field")
            val length = readVarint(stream, allowEof = false)!!
            if (length < 0 || length > MAX_ENTRY_BYTES) throw IllegalArgumentException("Entry too large")
            val entry = ByteArray(length.toInt())
            var read = 0
            while (read < entry.size) {
                val n = stream.read(entry, read, entry.size - read)
                if (n < 0) throw IllegalArgumentException("Truncated geodata")
                read += n
            }
            validateEntry(Proto(entry), kind == "geoip.dat")
            count++
        }
        if (count == 0) throw IllegalArgumentException("Empty geodata")
    }

    private fun readVarint(stream: InputStream, allowEof: Boolean): Long? {
        var value = 0L
        var shift = 0
        while (shift < 64) {
            val byte = stream.read()
            if (byte < 0) {
                if (allowEof && shift == 0) return null
                throw IllegalArgumentException("Truncated geodata")
            }
            value = value or ((byte and 127).toLong() shl shift)
            if (byte < 128) return value
            shift += 7
        }
        throw IllegalArgumentException("Invalid varint")
    }

    private fun validateEntry(item: Proto, geoip: Boolean) {
        var country = false
        var records = 0
        while (!item.done) {
            val (number, type) = item.key()
            if (number == 1 && type == 2) {
                val code = item.text()
                if (code.isEmpty() || code.length > 128) throw IllegalArgumentException("Invalid category")
                country = true
            } else if (number == 2 && type == 2) {
                val record = Proto(item.data())
                var value: ByteArray? = null
                var numeric = 0L
                while (!record.done) {
                    val (n, w) = record.key()
                    if ((if (geoip) n == 1 else n == 2) && w == 2) value = record.data()
                    else if ((if (geoip) n == 2 else n == 1) && w == 0) numeric = record.varint()
                    else record.skip(w)
                }
                if (value == null || value.isEmpty()) throw IllegalArgumentException("Empty record")
                if (geoip) {
                    if (value.size != 4 && value.size != 16 || numeric > value.size * 8L) throw IllegalArgumentException("Invalid CIDR")
                } else if (numeric > 3 || Proto.decode(value).isEmpty()) {
                    throw IllegalArgumentException("Invalid domain")
                }
                records++
            } else {
                item.skip(type)
            }
        }
        if (!country || records == 0) throw IllegalArgumentException("Incomplete category")
    }

    private class Proto(private val bytes: ByteArray) {
        private var offset = 0
        val done get() = offset == bytes.size

        fun varint(): Long {
            var value = 0L
            var shift = 0
            while (shift < 64) {
                if (offset >= bytes.size) throw IllegalArgumentException("Truncated geodata")
                val byte = bytes[offset++].toInt() and 255
                value = value or ((byte and 127).toLong() shl shift)
                if (byte < 128) return value
                shift += 7
            }
            throw IllegalArgumentException("Invalid varint")
        }

        fun key(): Pair<Int, Int> {
            val v = varint()
            if (v ushr 3 == 0L) throw IllegalArgumentException("Invalid field")
            return (v ushr 3).toInt() to (v and 7).toInt()
        }

        fun data(): ByteArray {
            val length = varint()
            if (length < 0 || length > bytes.size - offset) throw IllegalArgumentException("Truncated geodata")
            return bytes.copyOfRange(offset, offset + length.toInt()).also { offset += length.toInt() }
        }

        fun text(): String = decode(data())

        fun skip(wire: Int) {
            when (wire) {
                0 -> varint()
                1 -> offset += 8
                2 -> data()
                5 -> offset += 4
                else -> throw IllegalArgumentException("Invalid wire type")
            }
            if (offset > bytes.size) throw IllegalArgumentException("Truncated geodata")
        }

        companion object {
            fun decode(bytes: ByteArray): String = Charsets.UTF_8.newDecoder()
                .onMalformedInput(CodingErrorAction.REPORT)
                .onUnmappableCharacter(CodingErrorAction.REPORT)
                .decode(java.nio.ByteBuffer.wrap(bytes)).toString()
        }
    }
}

internal object NativeGeoStore {
    @Volatile private var store: GeoStore? = null

    private fun store(context: Context): GeoStore = store ?: synchronized(this) {
        store ?: GeoStore(
            context.filesDir,
            { name -> context.assets.open("flutter_assets/assets/binaries/$name") },
            {
                // v1.6.6 recorded the last download time through shared_preferences.
                try {
                    context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
                        .all["flutter.geo_last_updated"]?.let { (it as? Number)?.toLong() }
                } catch (_: Exception) { null }
            },
        ).also { store = it }
    }

    private fun defaultLog(level: String, message: String) {
        android.util.Log.i("TeapodGeo", "[$level] $message")
        VpnEventStreamHandler.sendLogEvent(level, message)
    }

    /** Verified geodata directory for Teapodcore.initCoreEnv. */
    fun activePath(context: Context, log: (String, String) -> Unit = ::defaultLog): String =
        store(context).activePath(log)

    fun prepare(context: Context): Boolean = try { activePath(context); true } catch (_: Exception) { false }
}
