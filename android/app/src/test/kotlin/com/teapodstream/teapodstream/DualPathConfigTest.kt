package com.teapodstream.teapodstream

import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class DualPathConfigTest {
    private fun profile() = JSONObject("""{
      "outbounds":[{"tag":"teapod-dualpath","protocol":"socks"}],
      "routing":{"rules":[{"type":"field","outboundTag":"teapod-dualpath","network":"tcp,udp"}]},
      "teapodDualPath":{"version":1,"mode":"adaptive","token":"01234567890123456789012345678901",
        "ca":"-----BEGIN CERTIFICATE-----\nTEST\n-----END CERTIFICATE-----",
        "naive":{"address":"192.0.2.1","serverName":"a.test","port":8443,"username":"user","password":"long-test-password"},
        "xhttp":{"address":"192.0.2.2","serverName":"b.test","port":8443,"uuid":"test-id","path":"/test"},
        "collector":{"address":"192.0.2.2","serverName":"b.test","port":27443}}
    }""")
    @Test fun outerTunnelBypassesInnerProxyAndMetadataIsRemoved() {
        val root = JSONObject(DualPathConfig.transform(profile().toString(), 12001, 12002, "local", "local-password"))
        assertFalse(root.has(DualPathConfig.KEY))
        val first = root.getJSONObject("routing").getJSONArray("rules").getJSONObject(0)
        assertEquals(DualPathConfig.OUTER, first.getString("outboundTag"))
        assertEquals(DualPathConfig.INBOUND, first.getJSONArray("inboundTag").getString(0))
        val server = root.getJSONArray("outbounds").getJSONObject(0).getJSONObject("settings").getJSONArray("servers").getJSONObject(0)
        assertEquals(12001, server.getInt("port"))
        assertEquals("local-password",server.getJSONArray("users").getJSONObject(0).getString("pass"))
        val tls = root.getJSONArray("outbounds").getJSONObject(1).getJSONObject("streamSettings").getJSONObject("tlsSettings")
        assertFalse(tls.getBoolean("allowInsecure"))
        assertEquals("verify",tls.getJSONArray("certificates").getJSONObject(0).getString("usage"))
        assertEquals("127.0.0.1",root.getJSONArray("inbounds").getJSONObject(0).getString("listen"))
        assertEquals("password",root.getJSONArray("inbounds").getJSONObject(0).getJSONObject("settings").getString("auth"))
    }
    @Test fun ordinaryProfilesAreUnchanged() {
        val value="""{"outbounds":[{"protocol":"freedom"}]}"""
        assertEquals(value,DualPathConfig.transform(value,1,2,"u","p"))
    }
    @Test fun independentFallbackHasDedicatedAuthenticatedRouting() {
        val p=profile()
        p.getJSONObject(DualPathConfig.KEY).put("expectedIps",org.json.JSONArray("[\"192.0.2.2\"]"))
            .put("fallback",JSONObject("""{"expectedIps":["192.0.2.3"],"outbound":{"protocol":"vless","settings":{"vnext":[{"address":"192.0.2.3","port":443,"users":[{"id":"test"}]}]},"streamSettings":{"network":"tcp","security":"reality"}}}"""))
        val r=JSONObject(DualPathConfig.transform(p.toString(),12001,12002,"u","long-local-password",12003))
        val rules=r.getJSONObject("routing").getJSONArray("rules")
        assertEquals(DualPathConfig.FALLBACK,rules.getJSONObject(1).getString("outboundTag"))
        assertEquals(DualPathConfig.TAG,rules.getJSONObject(2).getString("outboundTag"))
        val inbound=r.getJSONArray("inbounds").getJSONObject(1)
        assertEquals("127.0.0.1",inbound.getString("listen"))
        assertEquals("password",inbound.getJSONObject("settings").getString("auth"))
        assertTrue(inbound.getJSONObject("settings").getBoolean("udp"))
        assertFalse(r.has(DualPathConfig.KEY))
    }
    @Test(expected=IllegalArgumentException::class) fun unknownModeIsRejected() {
        val root=profile();root.getJSONObject(DualPathConfig.KEY).put("mode","direct")
        DualPathConfig.spec(root)
    }
    @Test(expected=IllegalArgumentException::class) fun resolverRuleInjectionIsRejected() {
        val root=profile();root.getJSONObject(DualPathConfig.KEY).getJSONObject("naive").put("address","192.0.2.1, MAP * 127.0.0.1")
        DualPathConfig.spec(root)
    }
}
