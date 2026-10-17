package com.teapodstream.teapodstream

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelFileDescriptor
import android.os.PowerManager
import android.system.OsConstants
import android.util.LruCache
import androidx.core.app.NotificationCompat
import java.io.File
import java.net.HttpURLConnection
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Proxy
import java.net.Socket
import java.net.URL
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicReference
import teapodcore.Teapodcore
import teapodcore.XrayCallback
import teapodcore.TunValidator
import teapodcore.VpnProtector

class XrayVpnService : VpnService() {

    companion object {
        init {
            System.loadLibrary("vpnhelper")
        }

        @JvmStatic external fun nativeSetMaxFds(maxFds: Int): Int
        const val ACTION_CONNECT = "com.teapodstream.CONNECT"
        const val ACTION_DISCONNECT = "com.teapodstream.DISCONNECT"
        const val ACTION_CONNECT_QUICK = "com.teapodstream.CONNECT_QUICK" // reconnect from notification
        const val EXTRA_XRAY_CONFIG = "xray_config"
        const val EXTRA_SOCKS_PORT = "socks_port"
        const val EXTRA_SOCKS_USER = "socks_user"
        const val EXTRA_SOCKS_PASSWORD = "socks_password"
        const val EXTRA_EXCLUDED_PACKAGES = "excluded_packages"
        const val EXTRA_INCLUDED_PACKAGES = "included_packages"
        const val EXTRA_VPN_MODE = "vpn_mode"
        const val EXTRA_SS_PREFIX = "ss_prefix" // hex-encoded Outline prefix bytes
        const val EXTRA_PROXY_ONLY = "proxy_only" // start only SOCKS proxy, no VPN tunnel
        const val EXTRA_SHOW_NOTIFICATION = "show_notification" // show rich notification with speed
        const val EXTRA_KILL_SWITCH = "kill_switch" // block traffic when VPN drops unexpectedly
        const val EXTRA_ALLOW_ICMP = "allow_icmp" // allow ICMP echo (ping) through the tunnel
        const val EXTRA_BLOCK_QUIC = "block_quic" // reject UDP/443 inside the TUN via ICMP Port Unreachable
        const val EXTRA_IPV6 = "ipv6_enabled" // add IPv6 address/route to the TUN interface
        internal val coordinator = SessionCoordinator()
        @Volatile private var activeService: XrayVpnService? = null
        @Volatile var sessionId: Long = 0
            private set
        @Volatile var activePlanInfo: String = "{}"
            private set
        @Volatile var activeMode: String = "unknown"
            private set
        const val EXTRA_REQUEST_ID = "request_id"
        fun reserveConnectRequest(): Long =
            if (activeService?.isRunning?.get() == true && coordinator.isCurrent(sessionId)) sessionId else coordinator.invalidate()
        fun disconnectActive() {
            userRequestedDisconnect.set(true)
            coordinator.invalidate()
            activeService?.requestStop()
        }
        const val EXTRA_MTU = "mtu" // TUN MTU size

        // Static state tracker for querying from Dart
        @Volatile private var currentNativeState: String = "disconnected"
        // Tracks whether we are in TUN mode (not proxy-only). Used by getNativeState() to detect
        // a TUN fd closed externally (e.g. during a phone call) without onRevoke() being called.
        @Volatile private var tunModeActive = false

        @JvmStatic fun getNativeState(): String {
            return currentNativeState
        }

        // Set true on explicit user disconnect, false on connect — guards reconnectInternal()
        val userRequestedDisconnect = AtomicBoolean(false)

        // Active SOCKS credentials — stored so onListen can replay them with "connected".
        // AtomicReference ensures the three fields are always read/written as a consistent unit.
        private data class SocksCredentials(val port: Int, val user: String, val password: String)
        private val _socksCredentials = AtomicReference(SocksCredentials(0, "", ""))

        val activeSocksPort: Int get() = _socksCredentials.get().port
        val activeSocksUser: String get() = _socksCredentials.get().user
        val activeSocksPassword: String get() = _socksCredentials.get().password

        // Epoch-ms when VPN became connected; 0 when disconnected. Survives UI restarts because
        // the foreground service process stays alive. Flutter uses this to restore the timer.
        @Volatile var connectedAtMs: Long = 0
            private set

        @JvmStatic fun getSocksCredentials(): Map<String, Any> {
            val c = _socksCredentials.get()
            return mapOf("port" to c.port, "user" to c.user, "password" to c.password, "connectedAtMs" to connectedAtMs)
        }

        const val LOG_FILE_NAME = "vpn_log.txt"
        const val LOG_PREV_FILE_NAME = "vpn_log.prev.txt"
        // A long session with verbose logging must not grow the file without
        // bound; past this size the current log rotates into the prev slot.
        const val MAX_LOG_FILE_BYTES = 512L * 1024
        val LOG_FILE_LOCK = Any()

        private const val NOTIFICATION_CHANNEL_ID = "vpn_service"
        private const val NOTIFICATION_CHANNEL_MINIMAL_ID = "vpn_service_minimal"
        private const val NOTIFICATION_ID = 1

        // Independent HTTPS-port reachability probes; failure means unknown. Multiple providers so a
        // single blocked resolver (e.g. Google DNS unreachable in some regions) doesn't
        // make hasDirectInternet() report "no internet" forever, which would suppress
        // heartbeat failure counting and block reconnects. Yandex DNS covers networks
        // where foreign resolvers are filtered.
        private val CONNECTIVITY_CHECK_HOSTS = arrayOf("1.1.1.1", "8.8.8.8", "2606:4700:4700::1111")
        private const val STATS_INTERVAL_MS = 1_000L
        // tun2socks + xray together (1.6.6 allowed 5 s + 3 s); past it the stop keeps
        // running in the background and only new starts wait for it.
        private const val STOP_THREAD_TIMEOUT_MS = 10_000L
        // A reconnect/always-on/tile start refused while a late stop drained.
        private val restartAfterStop = AtomicBoolean(false)
        private const val RECONNECT_DEBOUNCE_MS = 2_000L
        // Failed CONNECT_QUICK reconnects are retried with linear backoff instead of
        // silently leaving the VPN off (and, with kill switch, traffic leaking).
        private const val MAX_RECONNECT_ATTEMPTS = 3
        private const val RECONNECT_RETRY_BASE_MS = 5_000L
        // Second screen-on probe, so one probe lost to a radio still waking up
        // doesn't cost a full reconnect.
        private const val WAKE_PROBE_RETRY_MS = 3_000L

        @Volatile private var totalUpload: Long = 0
        @Volatile private var totalDownload: Long = 0
        @Volatile private var lastUploadSpeed: Long = 0
        @Volatile private var lastDownloadSpeed: Long = 0

        private const val MAX_STATS_HISTORY = 300
        private val statsHistory = ArrayDeque<Pair<Long, Long>>(MAX_STATS_HISTORY)

        fun getStats(): Map<String, Long> = mapOf(
            "upload" to totalUpload,
            "download" to totalDownload,
            "uploadSpeed" to lastUploadSpeed,
            "downloadSpeed" to lastDownloadSpeed,
        )

        fun getStatsHistory(): List<Map<String, Long>> {
            synchronized(statsHistory) {
                return statsHistory.map { (up, down) ->
                    mapOf("uploadSpeed" to up, "downloadSpeed" to down)
                }
            }
        }

        fun prepareBinaries(context: android.content.Context): Boolean = NativeGeoStore.prepare(context)
    }

    private var tunInterface: ParcelFileDescriptor? = null
    private var statsThread: Thread? = null
    private val isRunning = AtomicBoolean(false)
    private var networkCallback: ConnectivityManager.NetworkCallback? = null
    @Volatile private var lastUnderlyingNetwork: Network? = null
    @Volatile private var lastConnectedMs: Long = 0L
    private var prefixProxy: PrefixTcpProxy? = null
    @Volatile private var showNotification = true
    private var screenReceiver: android.content.BroadcastReceiver? = null
    private var killSwitchEnabled = false
    @Volatile private var allowIcmpEnabled = true
    @Volatile private var blockQuicEnabled = false
    private var proxyOnlyMode = false
    private val networkChangeHandler = Handler(Looper.getMainLooper())
    // Last speed line posted to the connected notification; null forces the next
    // stats tick to post (reset on every state change).
    @Volatile private var lastSpeedNotificationText: String? = null
    private var pendingNetworkRunnable: Runnable? = null
    private val reconnectAttempts = AtomicInteger(0)
    // Heartbeat reconnects in a row that never saw a successful probe (server
    // unreachable while the network is fine). Drives HeartbeatMonitor's backoff;
    // reset by any successful probe or an explicit connect.
    private val unhealthyReconnects = AtomicInteger(0)
    // Set while a screen-on probe runs, so quick screen toggles can't stack probes.
    private val wakeProbeInFlight = AtomicBoolean(false)
    @Volatile private var notificationChannelsReady = false
    private val heartbeat = HeartbeatMonitor(object : HeartbeatMonitor.Deps {
        override val running: Boolean get() = isRunning.get()
        override val tunModeActive: Boolean get() = Companion.tunModeActive
        override val socksPort: Int get() = activeSocksPort
        override fun socksAuth(): Pair<String, String> =
            _socksCredentials.get().let { it.user to it.password }
        override fun isTunRunning() = Teapodcore.isTunRunning()
        override fun tunActiveConnections() = Teapodcore.tunActiveConnections()
        override fun tunLastRxActivityMs() = Teapodcore.getTunLastRxActivityMs()
        override fun tunStatsLine(): String = Teapodcore.getTunStatsLine()
        override fun hasDirectInternet() = this@XrayVpnService.hasDirectInternet()
        override fun hasUnderlyingNetwork() = findPhysicalNetwork() != null
        override fun requestReconnect(afterProbeFailure: Boolean) {
            if (afterProbeFailure) unhealthyReconnects.incrementAndGet()
            reconnectInternal()
        }
        override fun onProbeSuccess() = unhealthyReconnects.set(0)
        override fun reconnectBackoffMs() = HeartbeatMonitor.backoffForStreak(unhealthyReconnects.get())
        override fun log(level: String, message: String) = this@XrayVpnService.log(level, message)
    })

    private val tunAddress = "10.120.230.1"
    private val tunNetmask = "255.255.255.0"
    @Volatile private var tunMtu = 1500
    private val tunDns    = "1.1.1.1"

    override fun onCreate() {
        super.onCreate()
        VpnEventStreamHandler.appContext = applicationContext
        activeService = this
        coordinator.execute { migrateConnectionParamsIfNeeded() }
        Teapodcore.registerVpnProtector(object : VpnProtector {
            override fun protect(fd: Long): Boolean {
                val result = this@XrayVpnService.protect(fd.toInt())
                android.util.Log.i("TeapodVPN", "[protect] fd=$fd result=$result")
                return result
            }
        })
        registerScreenReceiver()
    }

    private fun migrateConnectionParamsIfNeeded() {
        val oldFile = File(filesDir, "last_connection.json")
        if (!oldFile.exists()) return
        try {
            val json = org.json.JSONObject(oldFile.readText())
            val meta = org.json.JSONObject().apply {
                put("socksPort", json.optInt("socksPort", 10808))
                put("excludedPackages", json.optJSONArray("excludedPackages") ?: org.json.JSONArray())
                put("includedPackages", json.optJSONArray("includedPackages") ?: org.json.JSONArray())
                put("vpnMode", json.optString("vpnMode", "allExcept"))
                val ssPrefix = json.optString("ssPrefix")
                if (ssPrefix.isNotEmpty()) put("ssPrefix", ssPrefix)
                put("proxyOnly", json.optBoolean("proxyOnly", false))
                put("showNotification", json.optBoolean("showNotification", true))
                put("killSwitch", json.optBoolean("killSwitch", false))
            }
            File(filesDir, "last_connection_meta.json").writeText(meta.toString())
            oldFile.delete()
        } catch (_: Exception) { /* Keep migration input for a later retry. */ }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        // Every startForegroundService path enters foreground, even a cancelled start.
        ensureForeground()
        if (intent?.action == ACTION_DISCONNECT) {
            disconnectActive()
            return START_NOT_STICKY
        }
        val requestId = if (intent?.hasExtra(EXTRA_REQUEST_ID) == true)
            intent.getLongExtra(EXTRA_REQUEST_ID, -1) else reserveConnectRequest()
        coordinator.execute {
            if (!coordinator.isCurrent(requestId)) {
                if (!isRunning.get()) { setState(idleState()); stopSelfResult(startId) }
                return@execute
            }
            if (isRunning.get()) { replayStateToUi(); return@execute }
            try {
                val snapshot = if (intent?.action == ACTION_CONNECT) {
                    val params = ConnectionParams(
                        intent.getIntExtra(EXTRA_SOCKS_PORT, 10808),
                        intent.getStringArrayListExtra(EXTRA_EXCLUDED_PACKAGES) ?: emptyList(),
                        intent.getStringArrayListExtra(EXTRA_INCLUDED_PACKAGES) ?: emptyList(),
                        intent.getStringExtra(EXTRA_VPN_MODE) ?: "allExcept",
                        intent.getStringExtra(EXTRA_SS_PREFIX),
                        intent.getBooleanExtra(EXTRA_PROXY_ONLY, false),
                        intent.getBooleanExtra(EXTRA_SHOW_NOTIFICATION, true),
                        intent.getBooleanExtra(EXTRA_KILL_SWITCH, false),
                        intent.getBooleanExtra(EXTRA_ALLOW_ICMP, true),
                        intent.getBooleanExtra(EXTRA_BLOCK_QUIC, false),
                        intent.getBooleanExtra(EXTRA_IPV6, false),
                        intent.getIntExtra(EXTRA_MTU, 1500).coerceIn(576, 9000),
                        intent.getStringExtra("planInfo") ?: "{}")
                    NativeSnapshot(intent.getStringExtra(EXTRA_XRAY_CONFIG) ?: "", params, requestId)
                } else {
                    if (intent?.action != ACTION_CONNECT_QUICK && File(filesDir, "user_disconnected.flag").exists()) {
                        setState(idleState()); return@execute
                    }
                    // START_STICKY restart in the process that just saw onRevoke: wait for
                    // an explicit connect (always-on restarts carry an intent and still run).
                    if (intent == null && userRequestedDisconnect.get()) {
                        setState(idleState()); return@execute
                    }
                    NativeSnapshotStore(filesDir).load()
                }
                if (snapshot == null) { setState(idleState()); openApp(); return@execute }
                if (!snapshot.params.proxyOnly && VpnService.prepare(this) != null) {
                    connectionError("VPN_PERMISSION_REQUIRED"); setState(idleState()); openApp(); return@execute
                }
                startSnapshot(snapshot, requestId, intent?.action != ACTION_CONNECT)
            } catch (e: Exception) {
                connectionError(if (e is ConnectionFailure) e.code else "INVALID_SNAPSHOT")
                setState(idleState())
            }
        }
        return START_STICKY
    }

    /** [persist] records an explicit user disconnect so boot/always-on don't undo it. */
    private fun requestStop(persist: Boolean = true) {
        if (persist) try { File(filesDir, "user_disconnected.flag").createNewFile() } catch (_: Exception) {}
        restartAfterStop.set(false)
        coordinator.execute {
            setState("disconnecting")
            stopVpn(explicit = true)
            closeTunSink()
            setState(if (coordinator.runtimeBlocked) "stopBlocked" else "disconnected")
        }
    }

    private fun connectionError(code: String) {
        log("error", "Connection rejected: $code")
        VpnEventStreamHandler.sendEvent(mapOf("type" to "connectionError", "code" to code, "sessionId" to sessionId))
    }

    private fun startSnapshot(snapshot: NativeSnapshot, requestId: Long, reconnect: Boolean) {
        if (!coordinator.isCurrent(requestId)) return
        if (coordinator.stopPending) {
            // Resumed by onLateRuntimeStop once the previous stop leaves the core.
            if (reconnect) restartAfterStop.set(true)
            throw ConnectionFailure("NATIVE_STOP_TIMEOUT", "Ядро ещё завершает предыдущую сессию")
        }
        if (coordinator.runtimeBlocked) throw ConnectionFailure("NATIVE_STOP_FAILED", "Перезапустите приложение: ядро не завершило остановку")
        val p = snapshot.params
        // Validate before replacing a held TUN or changing the applied policy.
        AllowedApplications.validatePolicy(p.vpnMode, p.proxyOnly, p.ssPrefix, p.includedPackages,
            android.os.Process.myUid()) { packageManager.getPackageUid(it, 0) }
        prepareBinaries(this)
        Teapodcore.initCoreEnv(NativeGeoStore.path(this), "")
        CoreConfigValidator.validate(snapshot.config)
        if (!coordinator.isCurrent(requestId)) return
        sessionId = requestId
        userRequestedDisconnect.set(false)
        if (!reconnect) {
            // An explicit connect starts fresh instead of inheriting up to 5 min of backoff.
            reconnectAttempts.set(0)
            unhealthyReconnects.set(0)
        }
        File(filesDir, "user_disconnected.flag").delete()
        showNotification = p.showNotification
        activePlanInfo = p.planInfo
        val pending = snapshot.copy(revision = requestId)
        NativeSnapshotStore(filesDir).save(pending, pending = true)
        val (user, password) = extractSocksFromConfig(snapshot.config)
        startVpn(snapshot.config, p.socksPort, user, password,
            p.excludedPackages, p.includedPackages, p.vpnMode, p.ssPrefix, p.proxyOnly,
            p.killSwitch, p.allowIcmp, p.blockQuic, p.ipv6Enabled, p.mtu, reconnect)
        if (isRunning.get() && currentNativeState == "connected" && coordinator.isCurrent(requestId)) {
            NativeSnapshotStore(filesDir).save(pending, pending = false)
        }
    }

    private fun extractSocksFromConfig(configJson: String): Pair<String, String> {
        return try {
            val inbounds = org.json.JSONObject(configJson).getJSONArray("inbounds")
            for (i in 0 until inbounds.length()) {
                val inbound = inbounds.getJSONObject(i)
                // Match by protocol, not tag: mergeWithRaw keeps the subscription's
                // own socks tag (usually "socks") so its routing rules still match.
                if (inbound.optString("protocol") == "socks") {
                    val accounts = inbound.optJSONObject("settings")
                        ?.optJSONArray("accounts") ?: continue
                    if (accounts.length() > 0) {
                        val acc = accounts.getJSONObject(0)
                        val user = acc.optString("user", "")
                        val pass = acc.optString("pass", "")
                        log("debug", "extractSocksFromConfig: extracted creds (auth=${user.isNotEmpty()})")
                        return user to pass
                    }
                }
            }
            "" to ""
        } catch (_: Exception) {
            "" to ""
        }
    }

    private fun openApp() {
        packageManager.getLaunchIntentForPackage(packageName)
            ?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ?.let { startActivity(it) }
    }

    private fun startVpn(
        xrayConfig: String,
        socksPort: Int,
        socksUser: String,
        socksPassword: String,
        excludedPackages: List<String>,
        includedPackages: List<String>,
        vpnMode: String,
        ssPrefix: String? = null,
        proxyOnly: Boolean = false,
        killSwitch: Boolean = false,
        allowIcmp: Boolean = true,
        blockQuic: Boolean = false,
        ipv6Enabled: Boolean = false,
        mtu: Int = 1500,
        isReconnect: Boolean = false,
    ) {
        if (!isRunning.compareAndSet(false, true)) {
            log("info", "startVpn skipped: VPN already running")
            replayStateToUi()
            return
        }
        // Keep the previous TUN (kill-switch sink left by a reconnect) open until the
        // new one is established: establish() atomically replaces the interface, so
        // app traffic is blackholed by the old TUN instead of leaking while xray starts.
        val startOwner = sessionId
        val previousTun = tunInterface
        tunInterface = null
        killSwitchEnabled = killSwitch
        tunModeActive = !proxyOnly
        allowIcmpEnabled = allowIcmp
        blockQuicEnabled = blockQuic
        proxyOnlyMode = proxyOnly
        tunMtu = mtu.coerceIn(576, 9000)
        if (!isReconnect) clearLogFile()
        setState(if (isReconnect) "reconnecting" else "connecting")
        log("info", "Starting VPN (MTU: $tunMtu)")

        try {
            // Enable prefix proxy only when the ss:// URL contains ?prefix=.
            val finalConfig = if (ssPrefix != null) {
                injectPrefixProxy(xrayConfig, ssPrefix) ?: throw ConnectionFailure("PREFIX_START_FAILED", "Prefix transport failed")
            } else {
                xrayConfig
            }

            // Save the config as received, not finalConfig: CONNECT_QUICK re-applies
            // ssPrefix on load, and a saved copy already pointing at this session's
            // 127.0.0.1:<port> prefix proxy would chain the next one to a dead port.
            prepareBinaries(this)

            // Set up xray asset path before starting
            Teapodcore.initCoreEnv(NativeGeoStore.path(this), "")

            if (proxyOnly) {
                // Proxy-only mode: start Xray SOCKS proxy without TUN tunnel or tun2socks
                log("info", "Proxy-only mode: skipping TUN tunnel")
                try { previousTun?.close() } catch (_: Exception) {}

                startXrayAndWait(finalConfig)
                ensureNotStoppedDuringStart()

                log("info", "xray started (proxy-only, SOCKS on port $socksPort)")
                activeMode = "proxyOnly"
                resetStats()
                setConnected(socksPort, socksUser, socksPassword)
                heartbeat.start(isReconnect)
                log("info", "Proxy-only mode active")
            } else {
                val randomSubnet1 = (2..250).random()
                val randomSubnet2 = (2..250).random()
                val randomSubnet3 = (2..250).random()
                val dynamicTunIp = "10.$randomSubnet1.$randomSubnet2.$randomSubnet3"

                val dynamicSession = "Teapod-${System.currentTimeMillis() % 10000}"

                val builder = Builder()
                    .setSession(dynamicSession)
                    .setMtu(tunMtu)
                    .addAddress(dynamicTunIp, 32)
                    .addRoute("0.0.0.0", 0)
                    .addDnsServer(tunDns)
                    .setBlocking(true)
                    .setMetered(false)

                // Without an IPv6 address Android blocks the family for tunneled apps
                // (no leak): connect() fails instantly and apps fall back to IPv4.
                // With the address, literal-IPv6 destinations (e.g. Telegram DCs) hang
                // when the VPN server has no IPv6 connectivity (#81).
                if (ipv6Enabled) {
                    val hex1 = (1..65535).random().toString(16)
                    val hex2 = (1..65535).random().toString(16)
                    val hex3 = (1..65535).random().toString(16)
                    builder.addAddress("fd00:$hex1:$hex2:$hex3::1", 64)
                    builder.addRoute("::", 0)
                }

                val selectedApps = if (vpnMode == "onlySelected") {
                    AllowedApplications.resolve(includedPackages, android.os.Process.myUid()) { packageManager.getPackageUid(it, 0) }
                } else emptyMap()
                val installedAllowed = mutableSetOf<Int>()
                if (vpnMode == "onlySelected") {
                    for ((pkg, uid) in selectedApps) {
                        try { builder.addAllowedApplication(pkg); installedAllowed.add(uid) }
                        catch (_: PackageManager.NameNotFoundException) { /* Uninstalled during validation. */ }
                    }
                    if (installedAllowed.isEmpty()) throw ConnectionFailure("EMPTY_ALLOWED_APPS", "Выберите хотя бы одно приложение")
                } else {
                    for (pkg in excludedPackages) {
                        try { builder.addDisallowedApplication(pkg) } catch (_: PackageManager.NameNotFoundException) {}
                    }
                    builder.addDisallowedApplication(packageName)
                }

                val fdResult = nativeSetMaxFds(65536)
                log("info", "nativeSetMaxFds result: $fdResult")

                tunInterface = builder.establish() ?: throw IllegalStateException("Failed to establish TUN")
                // The new interface replaced the old one atomically — the sink fd can go now.
                try { previousTun?.close() } catch (_: Exception) {}
                log("info", "TUN established with IP $dynamicTunIp")

                // 1. Start xray-core (in-process library, not subprocess)
                startXrayAndWait(finalConfig)
                ensureNotStoppedDuringStart()
                log("info", "xray started")

                // 2. Resolve UIDs for split tunneling (tun2socks validator level)
                val allowedUids = if (vpnMode == "onlySelected") installedAllowed else resolveUids(vpnMode, includedPackages, excludedPackages)
                val validator = buildTunValidator(allowedUids, vpnMode)

                log("info", "Starting tun2socks: mode=$vpnMode uids=${allowedUids.size}")

                val tunErr = Teapodcore.startTun2Socks(
                    tunInterface!!.fd.toLong(),
                    tunMtu.toLong(),
                    socksPort.toLong(),
                    socksUser,
                    socksPassword,
                    allowIcmpEnabled,
                    blockQuicEnabled,
                    validator
                )
                if (tunErr.isNotEmpty()) throw IllegalStateException("tun2socks: $tunErr")
                ensureNotStoppedDuringStart()

                log("info", "tun2socks started successfully")

                activeMode = if (vpnMode == "allExcept" && excludedPackages.isEmpty()) "all" else vpnMode
                startStatsMonitoring()
                registerNetworkCallback()
                setConnected(socksPort, socksUser, socksPassword)
                heartbeat.start(isReconnect)
                log("info", "VPN connected successfully")
            }
        } catch (e: Exception) {
            if (e is StartCancelledException) {
                stopVpn(explicit = true)
                try { previousTun?.close() } catch (_: Exception) {}
                return
            }
            if (e is ConnectionFailure) connectionError(e.code)
            log("error", "Start failed: ${e.message}")
            // If no new TUN was established, restore the old kill-switch sink so
            // stopVpn keeps blocking traffic; otherwise the old fd is obsolete.
            if (tunInterface == null && previousTun != null && killSwitch && !proxyOnly) {
                tunInterface = previousTun
            } else {
                try { previousTun?.close() } catch (_: Exception) {}
            }
            val willRetry = isReconnect && !userRequestedDisconnect.get()
                    && reconnectAttempts.incrementAndGet() <= MAX_RECONNECT_ATTEMPTS
            // On final failure with kill switch keep the sink (explicit=false) so
            // traffic stays blocked instead of silently leaking past the VPN.
            stopVpn(resultState = "error", explicit = !willRetry && !killSwitch, reconnecting = willRetry)
            if (willRetry) {
                val attempt = reconnectAttempts.get()
                val delayMs = RECONNECT_RETRY_BASE_MS * attempt
                log("warning", "Reconnect attempt $attempt/$MAX_RECONNECT_ATTEMPTS failed, retrying in ${delayMs}ms")
                // Scheduled rather than slept on the session queue, so a disconnect
                // never waits behind it; disconnect/destroy invalidate startOwner.
                networkChangeHandler.postDelayed({
                    if (coordinator.isCurrent(startOwner) && !userRequestedDisconnect.get() && !isRunning.get()) {
                        startService(Intent(this, XrayVpnService::class.java).setAction(ACTION_CONNECT_QUICK))
                    }
                }, delayMs)
            }
        }
    }

    /**
     * Starts xray-core and blocks until it signals ready or error via callback (max 30s safety timeout).
     * Throws IllegalStateException if xray reports an error status.
     */
    private fun startXrayAndWait(config: String) {
        val owner = sessionId
        val latch = CountDownLatch(1)
        val failed = AtomicBoolean(false)

        Teapodcore.startXray(config, object : XrayCallback {
            override fun onStatus(status: Long, message: String) {
                if (!coordinator.isCurrent(owner)) return
                log("info", "[xray] $message")
                if (status != 0L) failed.set(true)
                latch.countDown()
            }
        })

        val deadline = android.os.SystemClock.elapsedRealtime() + 30_000
        while (!latch.await(100, TimeUnit.MILLISECONDS)) {
            ensureNotStoppedDuringStart()
            if (android.os.SystemClock.elapsedRealtime() >= deadline) throw IllegalStateException("xray start timeout (30s)")
        }
        if (failed.get()) throw IllegalStateException("xray failed to start")
    }

    /**
     * A disconnect that lands while xray is starting runs stopVpn concurrently; its
     * StopXray also fires the start callback ("Core stopped", status 0), which looks
     * like success. Bail out instead of bringing tun2socks up for a dead session.
     */
    private fun ensureNotStoppedDuringStart() {
        if (!isRunning.get() || userRequestedDisconnect.get() || !coordinator.isCurrent(sessionId)) throw StartCancelledException()
    }

    private class StartCancelledException : IllegalStateException("stopped while starting")

    /** State to report while no session runs: a kept kill-switch sink still blocks traffic. */
    private fun idleState(): String =
        if (coordinator.runtimeBlocked) "stopBlocked" else if (!isRunning.get() && tunInterface != null) "blocked" else "disconnected"

    /** Re-sends the current state so the UI can drop a stale connect attempt. */
    private fun replayStateToUi() {
        val state = currentNativeState
        if (state == "connected") {
            VpnEventStreamHandler.sendConnectedEvent(activeSocksPort, activeSocksUser, activeSocksPassword)
        } else {
            VpnEventStreamHandler.sendStateEvent(state)
        }
    }

    /**
     * Resolves UIDs for the given package lists based on vpnMode.
     * In "onlySelected" mode returns allowed UIDs; otherwise returns excluded UIDs
     * (including the app's own UID to prevent routing loops).
     */
    private fun resolveUids(
        vpnMode: String,
        includedPackages: List<String>,
        excludedPackages: List<String>,
    ): Set<Int> {
        val uids = mutableSetOf<Int>()
        val packages = if (vpnMode == "onlySelected") includedPackages else excludedPackages
        for (pkg in packages) {
            try {
                val uid = packageManager.getPackageUid(pkg, PackageManager.GET_META_DATA)
                uids.add(uid)
                log("info", "${if (vpnMode == "onlySelected") "Allowed" else "Excluded"} UID for $pkg: $uid")
            } catch (e: Exception) {
                log("warning", "Failed to get UID for $pkg: ${e.message}")
            }
        }

        try {
            val ownUid = packageManager.getPackageUid(packageName, PackageManager.GET_META_DATA)
            if (vpnMode == "onlySelected") {
                if (uids.remove(ownUid)) {
                    log("info", "Removed own UID ($ownUid) from Allowed list to prevent loop")
                }
            } else {
                uids.add(ownUid)
                log("info", "Excluded own UID ($packageName): $ownUid")
            }
        } catch (e: Exception) {
            log("warning", "Failed to resolve own UID: ${e.message}")
        }

        return uids
    }

    private fun buildTunValidator(allowedUids: Set<Int>, vpnMode: String): TunValidator {
        if (allowedUids.isEmpty() && vpnMode != "onlySelected") {
            return object : TunValidator {
                override fun onValidate(srcIP: String, srcPort: Long, dstIP: String, dstPort: Long, protocol: Long) = true
            }
        }
        val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager

        return object : TunValidator {
            override fun onValidate(srcIP: String, srcPort: Long, dstIP: String, dstPort: Long, protocol: Long): Boolean {
                var uid = -1
                var threwException = false
                try {
                    uid = cm.getConnectionOwnerUid(
                        protocol.toInt(),
                        InetSocketAddress(srcIP, srcPort.toInt()),
                        InetSocketAddress(dstIP, dstPort.toInt())
                    )
                } catch (_: Exception) {
                    threwException = true
                }

                if (threwException) {
                    // ONLY must never treat an unknown owner as an allowed application.
                    return vpnMode != "onlySelected"
                }

                // uid=-1 means no local owner (e.g. tethered client packets).
                // Apply the same vpnMode logic: in allExcept mode -1 is not excluded → allow;
                // in onlySelected mode -1 is not in the allowlist → block.
                val effectiveUid = if (uid < 0) -1 else uid
                return if (vpnMode == "onlySelected") {
                    effectiveUid in allowedUids
                } else {
                    effectiveUid !in allowedUids
                }
            }
        }
    }

    /**
     * Parses [xrayConfig] JSON, finds the first proxy Shadowsocks server address,
     * starts a [PrefixTcpProxy] that sends [prefixHex] bytes before forwarding,
     * and returns a modified config pointing Xray to the local proxy.
     */
    private fun injectPrefixProxy(xrayConfig: String, prefixHex: String): String? {
        return try {
            val prefixBytes = prefixHex.chunked(2)
                .map { it.toInt(16).toByte() }
                .toByteArray()

            val json = org.json.JSONObject(xrayConfig)
            val outbounds = json.getJSONArray("outbounds")
            var proxyOutbound: org.json.JSONObject? = null
            for (i in 0 until outbounds.length()) {
                val ob = outbounds.getJSONObject(i)
                if (ob.optString("tag") == "proxy") { proxyOutbound = ob; break }
            }
            if (proxyOutbound == null) return null

            val settings = proxyOutbound.getJSONObject("settings")
            val servers = settings.getJSONArray("servers")
            val server = servers.getJSONObject(0)
            val realHost = server.getString("address")
            val realPort = server.getInt("port")

            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            val ownUid = android.os.Process.myUid()
            val proxy = PrefixTcpProxy(realHost, realPort, prefixBytes) { client ->
                try {
                    val uid = cm.getConnectionOwnerUid(
                        OsConstants.IPPROTO_TCP,
                        client.remoteSocketAddress as InetSocketAddress,
                        InetSocketAddress(client.localAddress, client.localPort)
                    )
                    uid == ownUid
                } catch (_: Exception) {
                    false
                }
            }
            proxy.start()
            prefixProxy = proxy

            // Redirect Xray to the local proxy
            server.put("address", "127.0.0.1")
            server.put("port", proxy.localPort)

            log("info", "Prefix proxy: 127.0.0.1:${proxy.localPort} → $realHost:$realPort (${prefixBytes.size} prefix bytes)")
            json.toString()
        } catch (e: Exception) {
            log("warning", "Failed to start prefix proxy: ${e.message}")
            null
        }
    }

    override fun onRevoke() {
        // Android revoked the VPN (another VPN app, system settings) — not a user
        // disconnect. Stop this session and suppress sticky restarts in this process,
        // but leave the persisted flag alone so always-on and boot auto-start keep working.
        log("info", "VPN revoked by system")
        userRequestedDisconnect.set(true)
        coordinator.invalidate()
        requestStop(persist = false)
    }

    /** Закрывает TUN-sink kill switch'а, если сервис уже остановлен. */
    private fun closeTunSink() {
        if (isRunning.get()) return
        try { tunInterface?.close() } catch (_: Exception) {}
        tunInterface = null
    }

    private fun stopVpn(
        resultState: String = "disconnected",
        explicit: Boolean = false,
        reconnecting: Boolean = false,
    ) {
        if (!isRunning.compareAndSet(true, false)) return  // idempotent — safe to call multiple times
        log("info", "stopVpn: begin (explicit=$explicit, reconnecting=$reconnecting)")
        heartbeat.stop()
        tunModeActive = false
        lastUnderlyingNetwork = null
        lastConnectedMs = 0L
        pendingNetworkRunnable?.let { networkChangeHandler.removeCallbacks(it) }
        pendingNetworkRunnable = null

        var keptTunAsSink = false
        try {
            try { unregisterNetworkCallback() } catch (e: Exception) {
                log("warning", "unregisterNetworkCallback failed: ${e.message}")
            }

            statsThread?.let {
                try { it.interrupt(); it.join(1000) } catch (e: Exception) {
                    log("warning", "statsThread.interrupt failed: ${e.message}")
                }
            }
            statsThread = null

            try { prefixProxy?.stop() } catch (e: Exception) {
                log("warning", "prefixProxy.stop failed: ${e.message}")
            }
            prefixProxy = null

            // Close TUN fd early so tun2socks goroutines reading from it get EOF and
            // unblock immediately (tun2socks works on a dup'd fd, so this is safe to
            // skip too). Kill-switch path keeps TUN open intentionally (traffic sink) —
            // including during internal reconnects: the next startVpn() closes the old
            // TUN only after the replacement is established, so app traffic is
            // blackholed by the sink instead of leaking past the VPN in between.
            val keepTunAsSink = killSwitchEnabled && !explicit && !proxyOnlyMode
                    && tunInterface != null
                    && Build.VERSION.SDK_INT >= Build.VERSION_CODES.M
            keptTunAsSink = keepTunAsSink
            if (!keepTunAsSink) {
                try {
                    tunInterface?.close()
                } catch (e: Exception) {
                    log("warning", "tunInterface.close (early) failed: ${e.message}")
                }
                tunInterface = null
            }

            // Remove the creds file older versions kept for CONNECT_QUICK
            if (explicit) {
                try { File(filesDir, "socks_creds.json").delete() } catch (_: Exception) {}
            }

            log("info", "Stopping tun2socks and xray")
            val stopped = coordinator.stopRuntime(STOP_THREAD_TIMEOUT_MS, { activeService?.onLateRuntimeStop() }) {
                Teapodcore.stopTun2Socks()
                Teapodcore.stopXray()
            }
            if (!stopped) {
                log("warning", "Native stop not finished after ${STOP_THREAD_TIMEOUT_MS / 1000}s; new sessions wait for it")
                connectionError("NATIVE_STOP_TIMEOUT")
            }

            if (keepTunAsSink) {
                if (reconnecting) {
                    log("info", "Kill switch: TUN kept open as sink during reconnect")
                } else {
                    setUnderlyingNetworks(emptyArray())
                    log("info", "Kill switch active: TUN kept open, underlying networks cleared")
                }
            }

            // Keep xray_config.json for Quick Settings tile reconnect.
            // File is in process-private filesDir, not accessible to other apps.
            // if (explicit && !reconnecting) {
            //     try { File(filesDir, "xray_config.json").delete() } catch (_: Exception) {}
            // }
        } finally {
            // Don't overwrite "connecting" state when doing internal reconnect
            if (coordinator.runtimeBlocked) {
                setState("stopBlocked")
            } else if (!reconnecting) {
                connectedAtMs = 0
                // TUN-sink остался открытым (kill switch) — трафик заблокирован,
                // сообщаем отличимое от disconnected состояние.
                setState(if (keptTunAsSink) "blocked" else resultState)
            } else {
                // Clear credentials so startVpn picks up fresh ones from configFile
                _socksCredentials.set(SocksCredentials(0, "", ""))
                // The reconnect can wait up to 30 s for the network; without this the
                // UI and the tile kept showing "connected" over a torn-down tunnel.
                setState("reconnecting")
            }
            log("info", "stopVpn: done (state=${if (reconnecting) "reconnecting" else if (keptTunAsSink) "blocked" else resultState})")
        }
    }

    /** Runs on the session queue once a stop that outlived its deadline has left the core. */
    private fun onLateRuntimeStop() {
        log("info", "Native stop finished; new sessions are allowed again")
        if (isRunning.get()) return
        setState(idleState())
        if (restartAfterStop.getAndSet(false) && !userRequestedDisconnect.get()) {
            startService(Intent(this, XrayVpnService::class.java).setAction(ACTION_CONNECT_QUICK))
        }
    }

    override fun onDestroy() {
        try { unregisterReceiver(screenReceiver) } catch (_: Exception) {}
        screenReceiver = null
        coordinator.invalidate()
        coordinator.execute { stopVpn(explicit = true); closeTunSink() }
        if (activeService === this) activeService = null
        super.onDestroy()
    }

    private fun registerScreenReceiver() {
        screenReceiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(context: android.content.Context, intent: android.content.Intent) {
                when (intent.action) {
                    android.content.Intent.ACTION_SCREEN_OFF -> log("info", "Screen off")
                    android.content.Intent.ACTION_SCREEN_ON  -> {
                        log("info", "Screen on")
                        checkTunStallOnWake()
                    }
                    android.os.PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED -> {
                        val pm = context.getSystemService(POWER_SERVICE) as PowerManager
                        val idle = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) pm.isDeviceIdleMode else false
                        log("info", "Doze mode: ${if (idle) "entered" else "exited"}")
                    }
                }
            }
        }
        val filter = android.content.IntentFilter().apply {
            addAction(android.content.Intent.ACTION_SCREEN_OFF)
            addAction(android.content.Intent.ACTION_SCREEN_ON)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                addAction(android.os.PowerManager.ACTION_DEVICE_IDLE_MODE_CHANGED)
            }
        }
        registerReceiver(screenReceiver, filter)
    }

    private fun checkTunStallOnWake() {
        // Only for an established session: during startVpn the probe can't pass yet.
        if (!tunModeActive || !isRunning.get() || currentNativeState != "connected") return
        val lastRx = Teapodcore.getTunLastRxActivityMs()
        if (lastRx <= 0) return
        val idleSec = (System.currentTimeMillis() - lastRx) / 1000
        if (idleSec < HeartbeatMonitor.WAKE_PROBE_IDLE_MS / 1000) return
        // After Doze the xray upstream may be stale for new connections — but a quiet
        // TUN mostly means nobody used the phone. Reconnecting on every such unlock
        // cut all open connections right as the user picked the phone up (~3/4 of
        // all reconnects in a day of field logs), so check the tunnel end-to-end
        // first and reconnect only when it is actually dead.
        if (!wakeProbeInFlight.compareAndSet(false, true)) return
        val owner = sessionId
        Thread {
            try {
                if (heartbeat.probeOnce()) {
                    log("info", "Wake check: tunnel alive after ${idleSec}s idle, keeping session")
                    return@Thread
                }
                if (!isRunning.get() || !coordinator.isCurrent(owner)) return@Thread
                if (!hasDirectInternet()) {
                    // The network is still coming back; the network callback and the
                    // heartbeat take over once it does.
                    log("info", "Wake check: probe failed without direct internet, deferring to network callback")
                    return@Thread
                }
                Thread.sleep(WAKE_PROBE_RETRY_MS)
                if (!isRunning.get() || !coordinator.isCurrent(owner)) return@Thread
                if (heartbeat.probeOnce()) {
                    log("info", "Wake check: tunnel alive on retry, keeping session")
                    return@Thread
                }
                log("warning", "TUN stale on wake: no data for ${idleSec}s and probes failed, reconnecting")
                reconnectInternal()
            } catch (_: InterruptedException) {
            } finally {
                wakeProbeInFlight.set(false)
            }
        }.also { it.isDaemon = true; it.start() }
    }

    private fun resetStats() {
        totalUpload = 0; totalDownload = 0; lastUploadSpeed = 0; lastDownloadSpeed = 0
        synchronized(statsHistory) { statsHistory.clear() }
    }

    private fun startStatsMonitoring() {
        val owner = sessionId
        var lastUp = 0L
        var lastDown = 0L
        var lastTime = android.os.SystemClock.elapsedRealtime()

        totalUpload = 0
        totalDownload = 0
        lastUploadSpeed = 0
        lastDownloadSpeed = 0
        lastUp = 0
        lastDown = 0
        lastTime = System.currentTimeMillis()
        synchronized(statsHistory) { statsHistory.clear() }

        statsThread = Thread {
            while (isRunning.get() && coordinator.isCurrent(owner)) {
                try {
                    Thread.sleep(STATS_INTERVAL_MS)
                    val now = android.os.SystemClock.elapsedRealtime()
                    val elapsed = (now - lastTime) / 1000.0

                    val currentTx = Teapodcore.getTunUploadBytes()
                    val currentRx = Teapodcore.getTunDownloadBytes()

                    if (!coordinator.isCurrent(owner) || Thread.currentThread().isInterrupted) break
                    totalUpload = currentTx
                    totalDownload = currentRx

                    if (elapsed > 0) {
                        lastUploadSpeed = ((currentTx - lastUp) / elapsed).toLong().coerceAtLeast(0)
                        lastDownloadSpeed = ((currentRx - lastDown) / elapsed).toLong().coerceAtLeast(0)
                    }
                    lastUp = totalUpload
                    lastDown = totalDownload
                    lastTime = now
                    synchronized(statsHistory) {
                        if (statsHistory.size >= MAX_STATS_HISTORY) {
                            statsHistory.removeFirst()
                        }
                        statsHistory.addLast(Pair(lastUploadSpeed, lastDownloadSpeed))
                    }
                    VpnEventStreamHandler.sendStatsEvent(totalUpload, totalDownload, lastUploadSpeed, lastDownloadSpeed)
                    updateNotification(lastUploadSpeed, lastDownloadSpeed)
                } catch (_: InterruptedException) { break } catch (_: Exception) {}
            }
        }.also { it.isDaemon = true; it.start() }
    }

    private fun registerNetworkCallback() {
        val owner = sessionId
        try {
            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            // Pre-seed lastUnderlyingNetwork before registering so the initial onAvailable
            // callback sees prev == current and does NOT trigger a spurious reconnect.
            updateUnderlyingNetworks(cm)
            networkCallback = object : ConnectivityManager.NetworkCallback() {
                override fun onAvailable(network: Network) {
                    if (!coordinator.isCurrent(owner)) return
                    log("info", "Network available: $network")
                    val prev = lastUnderlyingNetwork
                    updateUnderlyingNetworks(cm)
                    val current = lastUnderlyingNetwork
                    // Trigger if network changed (prev→current) OR if prev was null but we now
                    // have a network (covers WiFi→LTE when onLost fired before onAvailable).
                    if (current != null && prev != current) {
                        scheduleNetworkChanged()
                    }
                }

                override fun onLost(network: Network) {
                    if (!coordinator.isCurrent(owner)) return
                    log("info", "Network lost: $network")
                    // Force-close all active tun2socks connections immediately on network loss.
                    // Stale gVisor TCP connections survive across brief network blips and cause
                    // app-level freezes (Telegram, etc.) because the SOCKS5 heartbeat cannot
                    // observe per-connection gVisor state. Closing them now forces apps to
                    // reconnect through a clean path when the network comes back.
                    // Only for the network the tunnel actually runs over: losing a secondary
                    // one (mobile data while on Wi-Fi) must not kill healthy connections.
                    if (tunModeActive && isRunning.get() && network == lastUnderlyingNetwork) {
                        coordinator.execute { if (coordinator.isCurrent(owner)) Teapodcore.forceTunCloseAllConnections() }
                    }
                    // Snapshot BEFORE clearing — needed for smooth-handover case where
                    // onAvailable(LTE) fires before onLost(WiFi): prev=wifi, after=LTE → trigger.
                    val prev = lastUnderlyingNetwork
                    if (lastUnderlyingNetwork == network) {
                        lastUnderlyingNetwork = null
                    }
                    updateUnderlyingNetworks(cm)
                    if (prev != null && lastUnderlyingNetwork != null && prev != lastUnderlyingNetwork) {
                        scheduleNetworkChanged()
                    }
                }

                override fun onCapabilitiesChanged(
                    network: Network,
                    networkCapabilities: NetworkCapabilities
                ) {
                    if (!coordinator.isCurrent(owner)) return
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        if (cm.activeNetwork == network) {
                            updateUnderlyingNetworks(cm)
                            // Captive portal / temporary internet loss: VALIDATED is removed
                            // without triggering onLost/onAvailable — detect and reconnect.
                            val validated = networkCapabilities.hasCapability(
                                NetworkCapabilities.NET_CAPABILITY_VALIDATED)
                            if (!validated) scheduleNetworkChanged()
                        }
                    }
                }
            }
            val request = NetworkRequest.Builder()
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .build()
            cm.registerNetworkCallback(request, networkCallback!!)
        } catch (e: Exception) {
            log("warning", "Failed to register network callback: ${e.message}")
        }
    }

    private fun findPhysicalNetwork(): Network? {
        val cm = getSystemService(ConnectivityManager::class.java)
        val activeNetwork = cm.activeNetwork ?: return null

        val caps = cm.getNetworkCapabilities(activeNetwork)
        if (caps == null || caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) {
            // Active is VPN — find WiFi first (preferred over LTE)
            val wifiNetwork = try {
                cm.allNetworks.firstOrNull { n ->
                    val c = cm.getNetworkCapabilities(n)
                    c?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true &&
                    c?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true
                }
            } catch (e: Exception) { null }

            if (wifiNetwork != null) return wifiNetwork

            // No WiFi — try any other internet network
            return try {
                cm.allNetworks.firstOrNull { n ->
                    val c = cm.getNetworkCapabilities(n)
                    c?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) == true &&
                    !c.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
                }
            } catch (e: Exception) { null }
        }

        // Active is not VPN — use it (WiFi or LTE)
        return activeNetwork
    }

    private fun updateUnderlyingNetworks(cm: ConnectivityManager) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val activeNetwork = cm.activeNetwork ?: run {
                setUnderlyingNetworks(null)
                lastUnderlyingNetwork = null
                return
            }

            // Use findPhysicalNetwork to get WiFi/LTE (not VPN)
            val physicalNetwork = findPhysicalNetwork()
            if (physicalNetwork == null) {
                if (lastUnderlyingNetwork != null) {
                    setUnderlyingNetworks(null)
                    lastUnderlyingNetwork = null
                    log("info", "All underlying networks lost")
                }
                return
            }

            if (physicalNetwork == lastUnderlyingNetwork) return
            lastUnderlyingNetwork = physicalNetwork
            setUnderlyingNetworks(arrayOf(physicalNetwork))
            log("info", "Underlying network set to physical: $physicalNetwork")
        }
    }

    private fun scheduleNetworkChanged() {
        // Only reconnect when fully connected — prevents spurious reconnects during the
        // initial startVpn() phase when onAvailable fires right after registration.
        if (currentNativeState != "connected") return
        // On mobile data Android fires onAvailable/onCapabilitiesChanged right after VPN
        // connects, causing an immediate false reconnect loop. Ignore changes within 5s of
        // connection — real network switches happen on a longer timescale.
        val msSinceConnect = System.currentTimeMillis() - lastConnectedMs
        if (lastConnectedMs > 0 && msSinceConnect < 5_000L) {
            log("debug", "Network change: ignored (VPN just connected ${msSinceConnect}ms ago)")
            return
        }
        log("info", "Network change: reconnect scheduled in ${RECONNECT_DEBOUNCE_MS}ms")
        pendingNetworkRunnable?.let { networkChangeHandler.removeCallbacks(it) }
        val owner = sessionId
        val r = Runnable { if (coordinator.isCurrent(owner)) reconnectInternal() }
        pendingNetworkRunnable = r
        networkChangeHandler.postDelayed(r, RECONNECT_DEBOUNCE_MS)
    }

    private fun reconnectInternal() {
        val owner = sessionId
        if (userRequestedDisconnect.get() || !isRunning.get()) return
        coordinator.reconnect(owner) {
            if (userRequestedDisconnect.get() || !isRunning.get()) return@reconnect
            val snapshot = try { NativeSnapshotStore(filesDir).load() } catch (_: Exception) { null }
            if (snapshot == null) { connectionError("INVALID_SNAPSHOT"); return@reconnect }
            reconnectAttempts.set(0) // each reconnect cycle gets its own retry budget
            stopVpn(resultState = "connecting", reconnecting = true)
            val deadline = android.os.SystemClock.elapsedRealtime() + 30_000
            while (coordinator.isCurrent(owner) && !userRequestedDisconnect.get() &&
                android.os.SystemClock.elapsedRealtime() < deadline && findPhysicalNetwork() == null) {
                Thread.sleep(RECONNECT_DEBOUNCE_MS)
            }
            if (!coordinator.isCurrent(owner) || userRequestedDisconnect.get()) return@reconnect
            try { startSnapshot(snapshot, coordinator.invalidate(), true) }
            catch (e: Exception) {
                // Keep the cause (EMPTY_ALLOWED_APPS, NATIVE_STOP_TIMEOUT, …) for the UI.
                connectionError(if (e is ConnectionFailure) e.code else "RECONNECT_FAILED")
                setState(idleState())
            }
        }
    }

    // Index of the host in CONNECTIVITY_CHECK_HOSTS that answered last — tried first on
    // the next probe so the happy path stays a single connection attempt.
    @Volatile private var lastGoodCheckHost = 0

    // Returns true if the physical network (not through VPN) can reach any of the
    // CONNECTIVITY_CHECK_HOSTS on TCP/443. A negative result is inconclusive.
    // The VpnService process UID is excluded from the tunnel, so sockets here bypass TUN.
    // bindSocket() additionally pins the socket to the physical interface, avoiding
    // stale routing state during WiFi→LTE handover.
    private fun hasDirectInternet(): Boolean {
        val n = CONNECTIVITY_CHECK_HOSTS.size
        val physicalNetwork = findPhysicalNetwork() ?: return false
        val cm = getSystemService(ConnectivityManager::class.java)
        if (cm.getNetworkCapabilities(physicalNetwork)?.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED) == true) return true
        for (attempt in 0 until n) {
            val idx = (lastGoodCheckHost + attempt) % n
            try {
                Socket().use { socket ->
                    physicalNetwork.bindSocket(socket)
                    socket.connect(
                        InetSocketAddress(CONNECTIVITY_CHECK_HOSTS[idx], 443),
                        RECONNECT_DEBOUNCE_MS.toInt()
                    )
                }
                lastGoodCheckHost = idx
                return true
            } catch (_: Exception) {
                // Try the next host — a single blocked/unreachable resolver must not
                // be mistaken for total loss of connectivity.
            }
        }
        return false
    }

    private fun unregisterNetworkCallback() {
        try {
            val cm = getSystemService(CONNECTIVITY_SERVICE) as ConnectivityManager
            networkCallback?.let {
                cm.unregisterNetworkCallback(it)
                networkCallback = null
            }
        } catch (e: Exception) {
            // Ignore
        }
    }

    private fun pendingFlags() =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M)
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        else
            PendingIntent.FLAG_UPDATE_CURRENT

    private fun speedText(uploadSpeed: Long, downloadSpeed: Long): String =
        "\u2191 ${formatSpeed(uploadSpeed)}  \u2193 ${formatSpeed(downloadSpeed)}"

    private fun buildConnectedNotification(uploadSpeed: Long, downloadSpeed: Long): Notification {
        val flags = pendingFlags()
        val stopIntent = PendingIntent.getService(this, 0,
            Intent(this, XrayVpnService::class.java).apply { action = ACTION_DISCONNECT }, flags)
        val openIntent = PendingIntent.getActivity(this, 0,
            packageManager.getLaunchIntentForPackage(packageName)
                ?.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), flags)
        val speedText = if (activeMode == "proxyOnly") "SOCKS-прокси · статистика TUN недоступна" else speedText(uploadSpeed, downloadSpeed)
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("TeapodStream VPN")
            .setContentText(speedText)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setContentIntent(openIntent)
            .addAction(android.R.drawable.ic_menu_close_clear_cancel, "Отключить", stopIntent)
            .build()
    }

    private fun buildDisconnectedNotification(): Notification {
        val flags = pendingFlags()
        val connectIntent = PendingIntent.getService(this, 1,
            Intent(this, XrayVpnService::class.java).apply { action = ACTION_CONNECT_QUICK }, flags)
        val openIntent = PendingIntent.getActivity(this, 0,
            packageManager.getLaunchIntentForPackage(packageName)
                ?.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP), flags)
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("TeapodStream VPN")
            .setContentText("Отключено")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setContentIntent(openIntent)
            .addAction(android.R.drawable.ic_media_play, "Подключить", connectIntent)
            .build()
    }

    private fun buildIntermediateNotification(isConnecting: Boolean, message: String? = null): Notification {
        val text = message ?: if (isConnecting) "Подключение…" else "Отключение…"
        return NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setContentTitle("TeapodStream VPN")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setProgress(0, 0, message == null)
            .build()
    }

    private fun buildMinimalNotification(): Notification =
        NotificationCompat.Builder(this, NOTIFICATION_CHANNEL_MINIMAL_ID)
            .setContentTitle("TeapodStream VPN")
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_MIN)
            .build()

    private fun ensureNotificationChannels(manager: NotificationManager) {
        if (notificationChannelsReady) return
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) {
            notificationChannelsReady = true
            return
        }
        manager.createNotificationChannel(
            NotificationChannel(NOTIFICATION_CHANNEL_ID, "VPN статус", NotificationManager.IMPORTANCE_LOW)
                .apply { description = "Скорость и управление VPN" }
        )
        manager.createNotificationChannel(
            NotificationChannel(NOTIFICATION_CHANNEL_MINIMAL_ID, "VPN (фоновый режим)", NotificationManager.IMPORTANCE_MIN)
                .apply { description = "Фоновый VPN-сервис" }
        )
        notificationChannelsReady = true
    }

    /** null for states that keep whatever notification is currently shown. */
    private fun buildNotificationFor(
        state: String,
        uploadSpeed: Long = 0,
        downloadSpeed: Long = 0,
    ): Notification? = when (VpnNotificationPolicy.variantFor(state, showNotification)) {
        VpnNotificationVariant.MINIMAL -> buildMinimalNotification()
        VpnNotificationVariant.CONNECTING -> buildIntermediateNotification(isConnecting = true)
        VpnNotificationVariant.DISCONNECTING -> buildIntermediateNotification(isConnecting = false)
        VpnNotificationVariant.CONNECTED -> buildConnectedNotification(uploadSpeed, downloadSpeed)
        VpnNotificationVariant.DISCONNECTED -> buildDisconnectedNotification()
        VpnNotificationVariant.STATUS_ONLY -> buildIntermediateNotification(false, when (state) {
            "stopBlocked" -> "Остановка ядра не завершена"
            "blocked" -> "Трафик заблокирован (kill switch)"
            "awaitingPermission" -> "Ожидание разрешения Android"
            else -> "Не удалось подключиться"
        })
        VpnNotificationVariant.KEEP_CURRENT -> null
    }

    private fun applyNotificationState(
        state: String,
        uploadSpeed: Long = 0,
        downloadSpeed: Long = 0,
    ) {
        val notification = buildNotificationFor(state, uploadSpeed, downloadSpeed) ?: return
        try {
            val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
            ensureNotificationChannels(manager)
            manager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            log("warning", "Notification update failed for state=$state: ${e.message}")
        }
    }

    /** Ensure the service is in foreground. Safe to call multiple times. */
    private fun ensureForeground() {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        ensureNotificationChannels(manager)
        // Match the live state: a CONNECT/CONNECT_QUICK that hits a running session
        // used to swap the "connected" notification for "Отключено", and an idle
        // tunnel never re-posted it (the speed text doesn't change at 0 B/s).
        lastSpeedNotificationText = null
        val notification = buildNotificationFor(currentNativeState)
            ?: if (showNotification) buildDisconnectedNotification() else buildMinimalNotification()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            log("warning", "startForeground failed: ${e.message}")
        }
    }

    private fun setState(state: String) {
        currentNativeState = state
        lastSpeedNotificationText = null
        applyNotificationState(state)
        VpnEventStreamHandler.sendStateEvent(state)
        sendBroadcast(Intent("com.teapodstream.STATE_CHANGED").apply { putExtra("state", state) })
    }

    private fun setConnected(socksPort: Int, socksUser: String, socksPassword: String) {
        currentNativeState = "connected"
        reconnectAttempts.set(0)
        val now = System.currentTimeMillis()
        connectedAtMs = now
        lastConnectedMs = now
        _socksCredentials.set(SocksCredentials(socksPort, socksUser, socksPassword))
        applyNotificationState("connected")
        VpnEventStreamHandler.sendConnectedEvent(socksPort, socksUser, socksPassword)
        sendBroadcast(Intent("com.teapodstream.STATE_CHANGED").apply {
            putExtra("state", "connected")
            putExtra("socksPort", socksPort)
        })
    }

    private fun updateNotification(uploadSpeed: Long, downloadSpeed: Long) {
        if (!showNotification) return
        // The stats loop calls this every second; re-posting an identical
        // notification (an idle tunnel shows "0 B/s" forever) is pure binder and
        // battery churn. Post only when the visible text actually changes.
        val text = speedText(uploadSpeed, downloadSpeed)
        if (text == lastSpeedNotificationText) return
        lastSpeedNotificationText = text
        applyNotificationState("connected", uploadSpeed, downloadSpeed)
    }

    private fun log(level: String, message: String) {
        android.util.Log.i("TeapodVPN", "[$level] $message")
        appendLogLine(level, message)
        if (level != "debug" || BuildConfig.DEBUG) {
            VpnEventStreamHandler.sendLogEvent(level, message)
        }
    }

    private fun appendLogLine(level: String, message: String) {
        try {
            val line = "${System.currentTimeMillis()}|$level|${message.replace("\n", " ")}\n"
            synchronized(LOG_FILE_LOCK) {
                val current = File(filesDir, LOG_FILE_NAME)
                if (current.length() > MAX_LOG_FILE_BYTES) {
                    val prev = File(filesDir, LOG_PREV_FILE_NAME)
                    prev.delete()
                    current.renameTo(prev)
                }
                java.io.FileWriter(current, true).use { it.write(line) }
            }
        } catch (_: Exception) {}
    }

    // Rotate instead of wiping: the previous session's log survives one connect,
    // so a hang that forced the user to reconnect can still be diagnosed afterwards.
    private fun clearLogFile() {
        try {
            synchronized(LOG_FILE_LOCK) {
                val current = File(filesDir, LOG_FILE_NAME)
                val prev = File(filesDir, LOG_PREV_FILE_NAME)
                prev.delete()
                if (current.exists() && current.length() > 0) {
                    current.renameTo(prev)
                }
                current.writeText("")
            }
        } catch (_: Exception) {}
    }


}
