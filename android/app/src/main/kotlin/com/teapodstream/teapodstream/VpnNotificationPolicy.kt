package com.teapodstream.teapodstream

internal enum class VpnNotificationVariant {
    MINIMAL,
    CONNECTING,
    DISCONNECTING,
    CONNECTED,
    DISCONNECTED,
    STATUS_ONLY,
    KEEP_CURRENT,
}

/** Pure notification-state mapping, kept separate from Android APIs for regression tests. */
internal object VpnNotificationPolicy {
    fun variantFor(state: String, showRichNotification: Boolean): VpnNotificationVariant {
        if (!showRichNotification) return VpnNotificationVariant.MINIMAL

        return when (state) {
            "connecting", "reconnecting" -> VpnNotificationVariant.CONNECTING
            "disconnecting" -> VpnNotificationVariant.DISCONNECTING
            "connected" -> VpnNotificationVariant.CONNECTED
            "disconnected" -> VpnNotificationVariant.DISCONNECTED
            "awaitingPermission", "blocked", "stopBlocked", "error" -> VpnNotificationVariant.STATUS_ONLY
            else -> VpnNotificationVariant.KEEP_CURRENT
        }
    }
}
