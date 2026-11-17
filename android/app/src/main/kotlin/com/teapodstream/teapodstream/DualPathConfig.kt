package com.teapodstream.teapodstream

import org.json.JSONArray
import org.json.JSONObject

/** Private managed-profile extension. Never include this object in diagnostics. */
internal object DualPathConfig {
    const val KEY = "teapodDualPath"
    const val TAG = "teapod-dualpath"
    const val OUTER = "teapod-dualpath-xhttp"
    const val INBOUND = "teapod-dualpath-outer"

    fun spec(config: JSONObject): JSONObject? {
        if (!config.has(KEY)) return null
        val s = config.getJSONObject(KEY)
        require(s.getInt("version") == 1) { "Unsupported DualPath profile version" }
        require(s.optString("mode", "adaptive") in listOf("adaptive", "standby", "split"))
        require(s.getString("token").length >= 32)
        require(s.getString("ca").contains("-----BEGIN CERTIFICATE-----"))
        for (name in listOf("naive", "xhttp", "collector")) {
            val endpoint = s.getJSONObject(name)
            require(endpoint.getString("address").matches(Regex("[a-zA-Z0-9.:-]{1,253}")))
            require(endpoint.getString("serverName").matches(Regex("[a-zA-Z0-9.-]{1,253}")))
            require(endpoint.getInt("port") in 1..65535)
        }
        require(s.getJSONObject("naive").getString("username").isNotEmpty())
        require(s.getJSONObject("naive").getString("password").length >= 16)
        require(s.getJSONObject("xhttp").getString("uuid").isNotEmpty())
        require(s.getJSONObject("xhttp").getString("path").startsWith("/"))
        val out = config.getJSONArray("outbounds")
        require((0 until out.length()).count { out.getJSONObject(it).optString("tag") == TAG } == 1)
        require((0 until out.length()).none { out.getJSONObject(it).optString("tag") == OUTER })
        return s
    }

    private fun j(vararg values: Pair<String, Any>): JSONObject = JSONObject().also { o -> values.forEach { o.put(it.first, it.second) } }
    private fun a(vararg values: Any): JSONArray = JSONArray().also { o -> values.forEach { o.put(it) } }

    fun transform(config: String, socks: Int, outer: Int, user: String, password: String): String {
        val root = JSONObject(config)
        val s = spec(root) ?: return config
        root.remove(KEY)
        val outbounds = root.getJSONArray("outbounds")
        for (i in 0 until outbounds.length()) {
            if (outbounds.getJSONObject(i).optString("tag") == TAG) {
                outbounds.put(i, j("tag" to TAG, "protocol" to "socks", "settings" to j("servers" to a(
                    j("address" to "127.0.0.1", "port" to socks, "users" to a(j("user" to user, "pass" to password)))))))
            }
        }
        val x = s.getJSONObject("xhttp")
        outbounds.put(j("tag" to OUTER, "protocol" to "vless",
            "settings" to j("vnext" to a(j("address" to x.getString("address"), "port" to x.getInt("port"),
                "users" to a(j("id" to x.getString("uuid"), "encryption" to "none"))))),
            "streamSettings" to j("network" to "xhttp", "security" to "tls",
                "tlsSettings" to j("serverName" to x.getString("serverName"), "allowInsecure" to false,
                    "alpn" to a("h2"), "certificates" to a(j("usage" to "verify", "certificate" to JSONArray(s.getString("ca").trim().lines())))),
                "xhttpSettings" to j("path" to x.getString("path"), "mode" to "stream-up"))))
        val inbounds = root.optJSONArray("inbounds") ?: JSONArray().also { root.put("inbounds", it) }
        require((0 until inbounds.length()).none { inbounds.getJSONObject(it).optString("tag") == INBOUND })
        inbounds.put(j("tag" to INBOUND, "listen" to "127.0.0.1", "port" to outer, "protocol" to "socks",
            "settings" to j("auth" to "password", "udp" to false, "accounts" to a(j("user" to user, "pass" to password)))))
        val routing = root.optJSONObject("routing") ?: JSONObject().also { root.put("routing", it) }
        val rules = a(j("type" to "field", "inboundTag" to a(INBOUND), "outboundTag" to OUTER))
        val oldRules = routing.optJSONArray("rules") ?: JSONArray()
        for (i in 0 until oldRules.length()) rules.put(oldRules.get(i))
        routing.put("rules", rules)
        return root.toString()
    }
}
