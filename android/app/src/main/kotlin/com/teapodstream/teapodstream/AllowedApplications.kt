package com.teapodstream.teapodstream

internal class ConnectionFailure(val code: String, message: String) : IllegalArgumentException(message)

internal object AllowedApplications {
    fun validatePolicy(mode: String, proxyOnly: Boolean, prefix: String?, packages: List<String>, ownUid: Int, lookup: (String) -> Int?) {
        if (mode != "allExcept" && mode != "onlySelected") throw ConnectionFailure("INVALID_VPN_MODE", "Unknown VPN policy")
        if (proxyOnly && prefix != null) throw ConnectionFailure("PREFIX_REQUIRES_TUN", "Prefix transport requires VPN mode")
        if (!proxyOnly && mode == "onlySelected") resolve(packages, ownUid, lookup)
    }

    fun resolve(packages: List<String>, ownUid: Int, lookup: (String) -> Int?): Map<String, Int> {
        val valid = packages.distinct().mapNotNull { name ->
            val uid = try { lookup(name) } catch (_: Exception) { null }
            if (uid == null || uid < 0 || uid == ownUid) null else name to uid
        }.toMap()
        if (valid.isEmpty()) throw ConnectionFailure("EMPTY_ALLOWED_APPS", "Выберите хотя бы одно приложение")
        return valid
    }
}
