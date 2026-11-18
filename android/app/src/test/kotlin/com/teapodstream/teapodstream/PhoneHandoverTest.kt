package com.teapodstream.teapodstream

import java.io.IOException
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test

class PhoneHandoverTest {
    private val lte = Uplink(false,true,false)
    private val wifi = Uplink(true,true,false)

    @Test fun preferUsableNetworkThroughPortalLogin() {
        val networks = linkedMapOf("lte" to lte)
        for (state in listOf(Uplink(true,false,false), Uplink(true,false,true), Uplink(true,true,true))) {
            networks["wifi"]=state
            assertEquals("lte", chooseUplink(networks,"lte"))
        }
        networks["wifi"]=wifi
        assertEquals("wifi",chooseUplink(networks,"lte"))
        networks.remove("wifi")
        assertEquals("lte",chooseUplink(networks,"wifi"))
        assertNull(chooseUplink(mapOf("wifi" to Uplink(true,false,true)),"wifi"))
        assertEquals("wifi",chooseUplink(mapOf("wifi" to Uplink(true,false,false)),null))
        assertEquals("second",chooseUplink(linkedMapOf("first" to lte,"second" to lte),"second"))
    }

    @Test fun optionalProcessMayFailToExecOrExitBeforeTheSelectorStarts() {
        for (command in listOf(listOf("/nonexistent-teapod-naive"),listOf("sh","-c","exit 21"))) {
            val ok=launchTransport(false) {
                val child=ProcessBuilder(command).start()
                if (child.waitFor(2,TimeUnit.SECONDS)) throw IOException("early exit")
            }
            assertFalse(ok)
            assertTrue(launchTransport(true) {})
        }
        assertThrows(ConnectionFailure::class.java) { launchTransport(true) { throw IOException("unavailable") } }
    }

    @Test fun proofOfPreviousPhysicalNetworkIsRejected() {
        val s=org.json.JSONObject("""{"schema_version":2,"runtime_generation":"g","process_generation":"p","config_hash":"h","boot_id":"b","network_epoch":"lte-g","session_id":"s","pid":12,"observed_boot":100,"valid_until_boot":108,"ready_A":false,"ready_B":true}""")
        fun read(epoch:String)=DualPathHealth.read(s.toString(),"g","h","b","p",102000,epoch)
        assertEquals("degraded",read("lte-g"))
        assertEquals("unknown",read("wifi-g"))
    }

    @Test fun localTransportRequiresBothTheConfiguredDestinationAndCredential() {
        val auth=ConnectAuth(setOf("entry.example"),443,"local","random-secret")
        val token=java.util.Base64.getEncoder().encodeToString("local:random-secret".toByteArray())
        fun accepts(host:String, value:String):Boolean {
            java.net.ServerSocket(0,1,java.net.InetAddress.getLoopbackAddress()).use { listener ->
                java.net.Socket(listener.inetAddress,listener.localPort).use { client ->
                    listener.accept().use { server ->
                        client.getOutputStream().write(("CONNECT $host HTTP/1.1\r\nProxy-Authorization: Basic $value\r\n\r\n").toByteArray())
                        return auth.accept(server)
                    }
                }
            }
        }
        assertTrue(accepts("entry.example:443",token))
        assertFalse(accepts("another.example:443",token))
        assertFalse(accepts("entry.example:8443",token))
        assertFalse(accepts("entry.example:443","wrong"))
    }
}
