package com.teapodstream.teapodstream

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import java.io.File

class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED &&
            intent.action != "android.intent.action.QUICKBOOT_POWERON"
        ) return

        val prefs = context.getSharedPreferences("FlutterSharedPreferences", Context.MODE_PRIVATE)
        if (!prefs.getBoolean("flutter.auto_start_on_boot", false)) return

        // Don't auto-start if user explicitly disconnected before reboot
        if (File(context.filesDir, "user_disconnected.flag").exists()) return

        // Don't auto-start if there's no saved connection config
        if (!File(context.filesDir, "xray_config.json").exists()) return

        context.startForegroundService(
            Intent(context, XrayVpnService::class.java).apply {
                action = XrayVpnService.ACTION_CONNECT_QUICK
            }
        )
    }
}
