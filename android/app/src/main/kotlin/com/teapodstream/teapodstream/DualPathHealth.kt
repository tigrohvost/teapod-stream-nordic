package com.teapodstream.teapodstream

import org.json.JSONObject

/** Evidence belongs to one process and one VPN configuration; elapsed time includes sleep. */
internal object DualPathHealth {
    fun read(raw: String, generation: String, hash: String, boot: String, process: String, nowMs: Long, networkEpoch: String = generation): String {
        return try {
            require(raw.length <= 65536)
            val s = JSONObject(raw)
            require(s.get("schema_version") == 2)
            for (key in listOf("runtime_generation","config_hash","boot_id","network_epoch","session_id","process_generation")) require(s.get(key) is String)
            require(s.get("ready_A") is Boolean && s.get("ready_B") is Boolean)
            require(s.get("observed_boot") is Number && s.get("valid_until_boot") is Number)
            require(s.getInt("schema_version") == 2)
            require(s.getString("runtime_generation") == generation && s.getString("config_hash") == hash)
            require(s.getString("boot_id") == boot && s.getLong("pid") > 0)
            require(s.getString("process_generation") == process)
            require(s.getString("network_epoch") == networkEpoch && s.getString("session_id").isNotEmpty())
            val observed = s.getDouble("observed_boot") * 1000
            val until = s.getDouble("valid_until_boot") * 1000
            require(observed.isFinite() && until.isFinite())
            require(nowMs.toDouble() >= observed && nowMs - observed <= 8000 && nowMs <= until && until <= observed + 8000)
            val a = s.getBoolean("ready_A"); val b = s.getBoolean("ready_B")
            if (s.has("selected_egress")) {
                val exit = s.getString("selected_egress")
                require(exit in listOf("primary","fallback","block"))
                if (exit == "block") return "blocked"
                val verified = s.getDouble("egress_verified_boot") * 1000
                require(verified.isFinite() && verified <= nowMs && nowMs - verified <= 35000)
                if (exit == "fallback") return "fallback"
            }
            when { a && b -> "ready"; a || b -> "degraded"; else -> "unavailable" }
        } catch (_: Exception) { "unknown" }
    }
}

internal class DualPathRetry {
    var attempts = 0; private set
    var nextAt = 0L; private set
    fun failed(now: Long, jitterMs: Long) {
        attempts = (attempts + 1).coerceAtMost(20)
        val delay = if (attempts >= 6) 300_000L else (1000L shl attempts).coerceAtMost(60_000)
        nextAt = now + delay + jitterMs.coerceIn(0, 1000)
    }
    fun stable() { attempts = 0; nextAt = 0 }
    fun allowed(now: Long) = now >= nextAt
}
