package com.teapodstream.teapodstream

/** Intent delivery is independent from the transient EventChannel listener. */
internal class PendingDeeplinks {
    private val pending = linkedMapOf<String, String>()
    private val acknowledged = linkedSetOf<String>()

    @Synchronized fun enqueue(id: String, uri: String) {
        if (!acknowledged.contains(id)) pending[id] = uri
    }
    @Synchronized fun snapshot(): List<Map<String, String>> = pending.map { (id, uri) ->
        mapOf("type" to "deeplink", "eventId" to id, "uri" to uri)
    }
    @Synchronized fun acknowledge(id: String) {
        pending.remove(id)
        acknowledged.add(id)
        while (acknowledged.size > 128) acknowledged.remove(acknowledged.first())
    }
}
