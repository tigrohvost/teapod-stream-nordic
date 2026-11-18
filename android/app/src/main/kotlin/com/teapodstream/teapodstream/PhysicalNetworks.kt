package com.teapodstream.teapodstream

import android.net.ConnectivityManager
import android.net.LinkProperties
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

internal data class Uplink(val wifi: Boolean, val validated: Boolean, val portal: Boolean) {
    companion object {
        fun from(c: NetworkCapabilities?): Uplink? {
            if (c == null || !c.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ||
                !c.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED) ||
                c.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return null
            return Uplink(c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI),
                c.hasCapability(NetworkCapabilities.NET_CAPABILITY_VALIDATED),
                c.hasCapability(NetworkCapabilities.NET_CAPABILITY_CAPTIVE_PORTAL))
        }
    }
}

internal fun <N> chooseUplink(networks: Map<N, Uplink>, current: N?): N? {
    val available = networks.filterValues { !it.portal }
    val ranked = available.mapValues { (_, n) -> (if (n.validated) 2 else 0) + (if (n.wifi) 1 else 0) }
    val best = ranked.values.maxOrNull() ?: return null
    return if (current != null && ranked[current] == best) current else ranked.entries.first { it.value == best }.key
}

internal class PhysicalNetworks(
    private val cm: ConnectivityManager,
    private val handler: Handler,
    private val active: Network?,
    private val initialLink: LinkProperties?,
    private val verify: ((Network) -> Boolean)?,
    private val changed: (Network?) -> Unit,
) : ConnectivityManager.NetworkCallback() {
    companion object {
        // Used only when starting the VPN or awaiting a physical network, outside callbacks.
        fun snapshot(cm: ConnectivityManager, preferred: Network? = null): Network? {
            val networks = cm.allNetworks.mapNotNull { n -> Uplink.from(cm.getNetworkCapabilities(n))?.let { n to it } }.toMap()
            if (preferred != null && networks[preferred]?.portal == false) return preferred
            return chooseUplink(networks, cm.activeNetwork)
        }

        private fun signature(properties: LinkProperties?) = properties?.let {
            listOf(it.interfaceName, it.linkAddresses.map { a -> a.toString() }.sorted(),
                it.dnsServers.map { a -> a.hostAddress }.sortedBy { a -> a },
                it.routes.map { r -> r.toString() }.sorted())
        }
    }

    private val caps = linkedMapOf<Network,Uplink>()
    private val links = mutableMapOf<Network,LinkProperties>()
    private val worker = Executors.newSingleThreadExecutor()
    @Volatile private var closed = false
    private var pending: Network? = null
    private var revision = 0L
    private var running = false
    private var switching = false
    private var activeLost = false
    private var activeLink = signature(initialLink)
    private var retry: Runnable? = null
    private var cellularRequest: ConnectivityManager.NetworkCallback? = null

    fun start() {
        // Seed the active network before Android sends the initial callback batch.
        val initialCaps = active?.let(cm::getNetworkCapabilities)
        if (active != null) Uplink.from(initialCaps)?.let { caps[active] = it }
        // A passive observer does not keep mobile data available when Android makes
        // Wi-Fi its default. Keep the already active data connection through login and
        // the managed-exit proof. close() releases the request on handover or stop.
        if (verify != null && initialCaps?.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) == true) {
            val request = NetworkRequest.Builder().addTransportType(NetworkCapabilities.TRANSPORT_CELLULAR)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build()
            val callback = ConnectivityManager.NetworkCallback()
            try {
                cm.requestNetwork(request, callback, handler)
                cellularRequest = callback
            } catch (_: RuntimeException) {
                android.util.Log.w("TeapodVPN", "Android did not grant the mobile network request")
            }
        }
        cm.registerNetworkCallback(NetworkRequest.Builder().addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), this, handler)
    }

    override fun onCapabilitiesChanged(network: Network, networkCapabilities: NetworkCapabilities) {
        if (closed) return
        val value = Uplink.from(networkCapabilities)
        val old = if (value == null) caps.remove(network) else caps.put(network,value)
        if (old != value) {
            if (network == pending) invalidateProbe()
            evaluate()
        }
    }

    override fun onLinkPropertiesChanged(network: Network, linkProperties: LinkProperties) {
        if (closed) return
        val new = signature(linkProperties)
        val old = signature(links.put(network,linkProperties))
        if (network == active) {
            if (activeLink != null && activeLink != new) { switch(active); return }
            activeLink = new
        }
        if (old != new) {
            if (network == pending) invalidateProbe()
            evaluate()
        }
    }

    override fun onLost(network: Network) {
        if (closed) return
        caps.remove(network); links.remove(network)
        if (network == active) activeLost = true
        if (network == pending) invalidateProbe()
        evaluate()
    }

    private fun invalidateProbe() {
        pending = null
        revision++
        retry?.let { handler.removeCallbacks(it) }
        retry = null
    }

    private fun switch(next: Network?) {
        if (closed || switching) return
        switching = true
        invalidateProbe()
        changed(next)
    }

    private fun evaluate() {
        if (closed || switching) return
        val next = chooseUplink(caps, active)
        if (next == active && !activeLost) { if (pending != null) invalidateProbe(); return }
        if (next == null) {
            if (activeLost || active != null && caps[active]?.portal == true) switch(null)
            return
        }
        if (active == null || activeLost || caps[active]?.portal == true || verify == null) {
            switch(next); return
        }
        // Retain a working LTE socket set until Wi-Fi has passed portal login, Android
        // validation, and an actual HTTPS operation through the managed exit on that Wi-Fi.
        if (caps[next]?.validated != true || links[next] == null) return
        if (running || pending == next) return
        pending = next
        val attempt = ++revision
        running = true
        try {
            worker.execute {
                val good = try { verify.invoke(next) } catch (_: Exception) { false }
                handler.post {
                    running = false
                    if (closed || switching) return@post
                    if (attempt != revision || chooseUplink(caps,active) != next) { evaluate(); return@post }
                    if (good) switch(next)
                    else {
                        // Keep pending set between retries so duplicate callbacks cannot spin.
                        val task = Runnable { if (!closed && revision == attempt) { pending=null; evaluate() } }
                        retry = task
                        handler.postDelayed(task, 12_000)
                    }
                }
            }
        } catch (_: RejectedExecutionException) { running = false }
    }

    fun close() {
        closed = true
        retry?.let { handler.removeCallbacks(it) }
        try { cm.unregisterNetworkCallback(this) } catch (_: IllegalArgumentException) {}
        cellularRequest?.let {
            try { cm.unregisterNetworkCallback(it) } catch (_: IllegalArgumentException) {}
            cellularRequest = null
        }
        worker.shutdownNow()
    }
}
