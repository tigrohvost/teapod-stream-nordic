package com.teapodstream.teapodstream

import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.InputStream
import java.nio.file.Files
import java.security.MessageDigest

class NativeGeoStoreTest {
    // Same minimal, structurally valid databases as the Dart geodata tests.
    private val geoip = bytes(10, 14, 10, 2, 85, 83, 18, 8, 10, 4, 1, 2, 3, 0, 16, 24)
    private val geosite = bytes(10, 21, 10, 2, 85, 83, 18, 15, 8, 2, 18, 11) + "example.com".toByteArray()
    // A second valid geoip ("RU", 5.6.7.0/24) to tell pairs apart.
    private val otherGeoip = bytes(10, 14, 10, 2, 82, 85, 18, 8, 10, 4, 5, 6, 7, 0, 16, 24)

    private val filesDir: File = Files.createTempDirectory("geo-store").toFile()
    private val root = File(filesDir, "geo")
    private val logs = mutableListOf<String>()
    private var hashes = 0

    @After fun cleanUp() { filesDir.deleteRecursively() }

    private fun bytes(vararg values: Int) = ByteArray(values.size) { values[it].toByte() }

    private fun sha(data: ByteArray) =
        MessageDigest.getInstance("SHA-256").digest(data).joinToString("") { "%02x".format(it) }

    private fun files(ip: ByteArray, site: ByteArray) = JSONObject()
        .put("geoip.dat", JSONObject().put("size", ip.size).put("sha256", sha(ip)))
        .put("geosite.dat", JSONObject().put("size", site.size).put("sha256", sha(site)))

    private fun store(legacyUpdatedAt: Long? = null): GeoStore {
        val manifest = JSONObject().put("schema", 1).put("files", files(geoip, geosite)).toString()
        val bundled: (String) -> InputStream = { name ->
            ByteArrayInputStream(when (name) {
                "manifest.json" -> manifest.toByteArray()
                "geoip.dat" -> geoip
                "geosite.dat" -> geosite
                else -> throw FileNotFoundException(name)
            })
        }
        return GeoStore(filesDir, bundled, { legacyUpdatedAt }) { hashes++; GeoStore.sha256Hex(it) }
    }

    private fun path(store: GeoStore) = store.activePath { level, message -> logs += "$level $message" }

    /** A generation as Dart's GeoDataRepository commits it. */
    private fun generation(name: String, ip: ByteArray, previous: String? = null, activate: Boolean = true): File {
        val dir = File(root, name).apply { mkdirs() }
        File(dir, "geoip.dat").writeBytes(ip)
        File(dir, "geosite.dat").writeBytes(geosite)
        val manifest = JSONObject().put("schema", 1).put("generation", name).put("files", files(ip, geosite))
        if (previous != null) manifest.put("previous", previous)
        File(dir, "manifest.json").writeText(manifest.toString())
        if (activate) File(root, "active.json").writeText(manifest.toString())
        return dir
    }

    private fun pointer() = JSONObject(File(root, "active.json").readText())

    @Test fun downloadedLegacyPairIsKeptInsteadOfBundled() {
        File(filesDir, "geoip.dat").writeBytes(otherGeoip)
        File(filesDir, "geosite.dat").writeBytes(geosite)
        val dir = File(path(store(legacyUpdatedAt = 1_700_000_000_000)))
        assertArrayEquals(otherGeoip, File(dir, "geoip.dat").readBytes())
        assertEquals("2023-11-14T22:13:20Z", pointer().getString("verifiedAt"))
        assertFalse("legacy copies are moved, not duplicated", File(filesDir, "geoip.dat").exists())
    }

    @Test fun untouchedLegacyCopyIsReplacedByCurrentBundle() {
        File(filesDir, "geoip.dat").writeBytes(otherGeoip)
        File(filesDir, "geosite.dat").writeBytes(geosite)
        val dir = File(path(store(legacyUpdatedAt = null)))
        assertArrayEquals(geoip, File(dir, "geoip.dat").readBytes())
        assertFalse(File(filesDir, "geoip.dat").exists())
    }

    @Test fun invalidLegacyPairFallsBackToBundled() {
        File(filesDir, "geoip.dat").writeText("<html>error</html>")
        File(filesDir, "geosite.dat").writeBytes(geosite)
        val dir = File(path(store(legacyUpdatedAt = 1L)))
        assertArrayEquals(geoip, File(dir, "geoip.dat").readBytes())
        assertTrue(logs.any { it.startsWith("warning") })
    }

    @Test fun damagedActiveRestoresThePreviousPair() {
        generation("generation-1", otherGeoip, activate = false)
        val damaged = generation("generation-2", geoip, previous = "generation-1")
        File(damaged, "geoip.dat").writeText("tampered")
        val dir = File(path(store()))
        assertEquals("generation-1", dir.name)
        assertEquals("generation-1", pointer().getString("generation"))
        assertEquals("generation-2", pointer().getString("restoredFrom"))
        assertTrue(logs.any { it.startsWith("warning") && "generation-1" in it })
    }

    @Test fun damagedActiveWithoutIntactPreviousUsesBundled() {
        val damaged = generation("generation-2", otherGeoip)
        File(damaged, "geosite.dat").delete()
        val dir = File(path(store()))
        assertArrayEquals(geoip, File(dir, "geoip.dat").readBytes())
        assertEquals("generation-2", pointer().getString("restoredFrom"))
    }

    @Test fun verifiedPairIsNotRehashedOnEveryStart() {
        val store = store()
        val dir = File(path(store))
        val afterInstall = hashes
        repeat(5) { assertEquals(dir.path, path(store)) }
        assertEquals("verification is cached per file state", afterInstall, hashes)
        File(dir, "geoip.dat").setLastModified(System.currentTimeMillis() - 60_000)
        path(store)
        assertEquals("a changed file is verified again", afterInstall + 1, hashes)
    }

    @Test fun onlyActiveAndPreviousGenerationsAreKept() {
        val old = generation("generation-1", geoip, activate = false)
        val previous = generation("generation-2", geoip, activate = false)
        generation("generation-3", geoip, previous = "generation-2")
        val abandoned = File(root, "generation-4").apply { mkdirs() }
        val staging = File(root, "generation-5").apply { mkdirs() } // a download in progress
        val hourAgo = System.currentTimeMillis() - 2 * 60 * 60 * 1000
        listOf(old, previous, abandoned).forEach { it.setLastModified(hourAgo) }
        assertEquals("generation-3", File(path(store())).name)
        assertFalse(old.exists())
        assertFalse(abandoned.exists())
        assertTrue(previous.exists())
        assertTrue(staging.exists())
    }

    @Test fun geodataValidatorMatchesTheDartRules() {
        GeoDatValidator.validate(ByteArrayInputStream(geoip), "geoip.dat")
        GeoDatValidator.validate(ByteArrayInputStream(geosite), "geosite.dat")
        for (invalid in listOf(ByteArray(0), "<html>error</html>".toByteArray(), geoip.copyOf(geoip.size - 1))) {
            try {
                GeoDatValidator.validate(ByteArrayInputStream(invalid), "geoip.dat")
                fail("accepted ${invalid.size} invalid bytes")
            } catch (_: IllegalArgumentException) {}
        }
    }
}
