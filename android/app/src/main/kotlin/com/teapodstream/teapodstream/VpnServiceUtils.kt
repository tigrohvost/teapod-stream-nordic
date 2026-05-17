package com.teapodstream.teapodstream

internal fun formatSpeed(bps: Long): String = when {
    bps >= 1_000_000 -> "%.1f MB/s".format(bps / 1_000_000.0)
    bps >= 1_000     -> "%.0f KB/s".format(bps / 1_000.0)
    else             -> "$bps B/s"
}

internal fun subnetMaskToPrefix(mask: String): Int {
    val parts = mask.split(".").map { it.toInt() }
    var prefix = 0
    for (part in parts) {
        var bits = part
        while (bits != 0) { prefix += bits and 1; bits = bits ushr 1 }
    }
    return prefix
}
