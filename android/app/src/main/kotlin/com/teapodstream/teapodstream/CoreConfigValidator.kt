package com.teapodstream.teapodstream

import teapodcore.Teapodcore

/** Pinned v1.1.15 adapter: loads the full JSON and creates an isolated outbound
 * instance, without changing the running singleton. '%' fails request creation
 * before any network request. Keep this contract covered when updating core.
 */
internal object CoreConfigValidator {
    fun validate(config: String) {
        if (config.length > 8 * 1024 * 1024) throw ConnectionFailure("CONFIG_TOO_LARGE", "Конфигурация слишком большая")
        val outbounds = org.json.JSONObject(config).optJSONArray("outbounds")
        if (outbounds != null) for (i in 0 until outbounds.length()) {
            val tls = outbounds.optJSONObject(i)?.optJSONObject("streamSettings")?.optJSONObject("tlsSettings") ?: continue
            if (tls.has("pinnedPeerCertificateChainSha256") || tls.has("echSettings")) {
                throw ConnectionFailure("UNSUPPORTED_TLS_FIELDS", "Обновите устаревшие поля TLS pin/ECH")
            }
        }
        try {
            Teapodcore.measureOutboundDelay(config, "%")
            throw ConnectionFailure("CORE_VALIDATOR_CONTRACT", "Unexpected validator result")
        } catch (e: Exception) {
            if (e.message?.startsWith("failed to create request:") == true) return
            throw ConnectionFailure("INVALID_CORE_CONFIG", "Ядро отклонило конфигурацию")
        }
    }
}
