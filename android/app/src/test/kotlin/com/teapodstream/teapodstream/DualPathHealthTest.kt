package com.teapodstream.teapodstream
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
class DualPathHealthTest {
    private fun sample() = JSONObject("""{"schema_version":2,"runtime_generation":"g","process_generation":"p","config_hash":"h","boot_id":"b","network_epoch":"g","session_id":"s","pid":12,"observed_boot":100,"valid_until_boot":108,"ready_A":true,"ready_B":true}""")
    private fun state(s: JSONObject, now: Long = 102000) = DualPathHealth.read(s.toString(),"g","h","b","p",now)
    @Test fun rejectsStaleFutureAndWrongProcess() {
        assertEquals("unknown",state(sample(),109000));assertEquals("unknown",state(sample(),99000))
        for ((k,v) in listOf("pid" to 0, "process_generation" to "old", "runtime_generation" to "old", "boot_id" to "old", "config_hash" to "old", "valid_until_boot" to 900))
            assertEquals("unknown",state(sample().put(k,v)))
        assertEquals("unknown",DualPathHealth.read("[]","g","h","b","p",102000))
    }
    @Test fun distinguishesDegradedAndUnavailable() {
        assertEquals("ready",state(sample()))
        assertEquals("degraded",state(sample().put("ready_A",false)))
        assertEquals("unavailable",state(sample().put("ready_A",false).put("ready_B",false)))
    }
    @Test fun invalidTypesAndIndependentExitLease() {
        assertEquals("unknown",state(sample().put("schema_version","2")))
        assertEquals("unknown",state(sample().put("ready_A","true")))
        assertEquals("fallback",state(sample().put("selected_egress","fallback").put("egress_verified_boot",99)))
        assertEquals("blocked",state(sample().put("selected_egress","block")))
        assertEquals("unknown",state(sample().put("selected_egress","fallback").put("egress_verified_boot",20)))
    }
    @Test fun crashLoopHasCooldownAndStableRuntimeResetsBudget() {
        val r=DualPathRetry();r.failed(1000,0);assertFalse(r.allowed(2000));assertTrue(r.allowed(3000))
        repeat(5) { r.failed(1000,0) };assertEquals(301000L,r.nextAt)
        r.stable();assertTrue(r.allowed(0));assertEquals(0,r.attempts)
    }
}
