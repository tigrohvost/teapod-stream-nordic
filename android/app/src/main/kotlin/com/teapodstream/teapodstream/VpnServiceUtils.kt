package com.teapodstream.teapodstream

internal fun formatSpeed(bps: Long): String {
    val bits = bps.coerceAtLeast(0) * 8.0
    return when {
        bits >= 1_000_000 -> "%.1f Mbit/s".format(java.util.Locale.ROOT, bits / 1_000_000)
        bits >= 1_000 -> "%.1f kbit/s".format(java.util.Locale.ROOT, bits / 1_000)
        else -> "${bits.toLong()} bit/s"
    }
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
