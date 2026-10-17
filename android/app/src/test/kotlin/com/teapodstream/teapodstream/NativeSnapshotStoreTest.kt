package com.teapodstream.teapodstream

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.file.Files

class NativeSnapshotStoreTest {
    @Test fun bootFindsCurrentSnapshotWithoutLegacyConfig() {
        val dir = Files.createTempDirectory("snapshot").toFile()
        try {
            assertFalse(NativeSnapshotStore(dir).hasStoredConnection())
            dir.resolve("connection_good.json").writeText("{}")
            assertTrue(NativeSnapshotStore(dir).hasStoredConnection())
        } finally { dir.deleteRecursively() }
    }

    @Test fun bootStillFindsPreSnapshotConnection() {
        val dir = Files.createTempDirectory("snapshot").toFile()
        try {
            dir.resolve("xray_config.json").writeText("{}")
            assertFalse("config without params can't be restored", NativeSnapshotStore(dir).hasStoredConnection())
            dir.resolve("last_connection_meta.json").writeText("{}")
            assertTrue(NativeSnapshotStore(dir).hasStoredConnection())
        } finally { dir.deleteRecursively() }
    }
}
