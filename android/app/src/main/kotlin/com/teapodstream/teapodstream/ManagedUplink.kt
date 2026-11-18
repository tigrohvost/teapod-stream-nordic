package com.teapodstream.teapodstream

import android.net.Network
import org.json.JSONArray
import org.json.JSONObject
import teapodcore.Teapodcore
import java.net.InetSocketAddress
import java.net.Socket
import java.security.MessageDigest
import java.util.Base64

/** A CONNECT listener always dials one configured TLS endpoint, on exactly one network. */
internal class ManagedUplink(val network: Network?) {
    private val relays = mutableListOf<PrefixTcpProxy>()

    private fun relay(on: Network?, host: String, port: Int, alias: String, user: String, password: String): PrefixTcpProxy {
        val auth = ConnectAuth(setOf(host, alias),port,user,password)
        return PrefixTcpProxy(host, port, byteArrayOf(), maxClients=32,
            connectUpstream={ socket,target,remotePort ->
                val net = on ?: throw java.io.IOException("No physical network")
                net.bindSocket(socket)
                socket.connect(InetSocketAddress(net.getByName(target),remotePort),5000)
            }, connectRequest=auth::accept, clientAllowed={ it.inetAddress.isLoopbackAddress })
    }

    fun naiveProxy(host: String, port: Int, alias: String, user: String, password: String): String {
        val proxy=relay(network,host,port,alias,user,password)
        relays.add(proxy); proxy.start()
        return "http://$user:$password@127.0.0.1:${proxy.localPort}"
    }

    private fun httpOutbound(tag: String, port: Int, user: String, password: String): JSONObject {
        val account=JSONObject().put("user",user).put("pass",password)
        val server=JSONObject().put("address","127.0.0.1").put("port",port).put("users",JSONArray().put(account))
        return JSONObject().put("tag",tag).put("protocol","http")
            .put("settings",JSONObject().put("servers",JSONArray().put(server)))
    }

    private fun pin(on: Network?, outbound: JSONObject, outbounds: JSONArray, user: String, password: String): PrefixTcpProxy {
        val upstream=outbound.getJSONObject("settings").getJSONArray("vnext").getJSONObject(0)
        val stream=outbound.getJSONObject("streamSettings")
        val host=upstream.getString("address")
        val tag=outbound.getString("tag")+"-physical"
        val proxy=relay(on,host,upstream.getInt("port"),host,user,password)
        try {
            stream.put("sockopt",JSONObject().put("dialerProxy",tag))
            outbounds.put(httpOutbound(tag,proxy.localPort,user,password))
            proxy.start()
            return proxy
        } catch (e: Exception) { proxy.stop(); throw e }
    }

    fun pinOutbound(outbound: JSONObject, outbounds: JSONArray, user: String, password: String) {
        relays.add(pin(network,outbound,outbounds,user,password))
    }

    fun verifyCandidate(candidate: Network, source: JSONObject, user: String, password: String): Boolean {
        val outbound=JSONObject(source.toString()).put("tag","proxy")
        val outbounds=JSONArray().put(outbound)
        val proxy=pin(candidate,outbound,outbounds,user,password)
        return try {
            val config=JSONObject().put("outbounds",outbounds).toString()
            listOf("https://www.google.com/generate_204","https://cp.cloudflare.com/generate_204").any {
                !Thread.currentThread().isInterrupted && try { Teapodcore.measureOutboundDelay(config,it) >= 0 }
                catch (_: Exception) { false }
            }
        } finally { proxy.stop() }
    }

    fun close() { relays.forEach { it.stop() }; relays.clear() }
}

internal class ConnectAuth(hosts: Set<String>, port: Int, user: String, password: String) {
    private val authorities=hosts.map {
        if (':' in it) "[${it.removeSurrounding("[","]")}]:$port".lowercase() else "${it.lowercase()}:$port"
    }.toSet()
    private val credential="Basic "+Base64.getEncoder().encodeToString("$user:$password".toByteArray())
    fun accept(socket: Socket): Boolean {
        val bytes=java.io.ByteArrayOutputStream()
        val input=socket.getInputStream()
        var tail=0
        val deadline=System.nanoTime()+5_000_000_000L
        while (bytes.size()<8192 && System.nanoTime()<deadline) {
            val b=input.read()
            if (b<0) return false
            bytes.write(b); tail=(tail shl 8) or b
            if (tail==0x0d0a0d0a) break
        }
        if (tail!=0x0d0a0d0a) return false
        val lines=bytes.toString("ISO-8859-1").split("\r\n")
        val request=lines.first().split(' ')
        if (request.size!=3 || request[0]!="CONNECT" || request[1].lowercase() !in authorities ||
            request[2] !in setOf("HTTP/1.0","HTTP/1.1")) return false
        val authorization=lines.drop(1).filter { it.substringBefore(':').equals("Proxy-Authorization",true) }
            .singleOrNull()?.substringAfter(':')?.trim().orEmpty()
        if (MessageDigest.isEqual(authorization.toByteArray(),credential.toByteArray())) return true
        socket.getOutputStream().write(("HTTP/1.1 407 Proxy Authentication Required\r\n"+
            "Proxy-Authenticate: Basic realm=\"Teapod\"\r\nConnection: close\r\nContent-Length: 0\r\n\r\n").toByteArray())
        return false
    }
}
