package com.worldbrief.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.LinkProperties
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import java.net.Inet4Address
import java.net.InetAddress

/**
 * Finds a World Brief server on the network the phone is already on.
 *
 * The desktop app listens on 8011 by default, on a machine in the same house. Sweeping the
 * local /24 for that port takes a couple of seconds and saves the user typing an IP address.
 */
object Discovery {

    private val PORTS = listOf(8011, 8012, 8000, 8080)
    private const val CONCURRENCY = 48
    private const val PROBE_TIMEOUT_MS = 700

    /** Candidate addresses worth trying before a full sweep: the emulator host and mDNS names. */
    private val SHORTCUTS = listOf("10.0.2.2", "worldbrief.local", "localhost")

    data class Found(val url: String, val host: String)

    suspend fun scan(
        context: Context,
        onProgress: (checked: Int, total: Int) -> Unit = { _, _ -> },
    ): List<Found> = withContext(Dispatchers.IO) {
        val results = mutableListOf<Found>()

        for (host in SHORTCUTS) {
            for (port in PORTS) {
                val url = "http://$host:$port"
                if (Api.probe(url, PROBE_TIMEOUT_MS)) results += Found(url, host)
            }
        }

        val prefix = subnetPrefix(context)
        if (prefix == null) {
            onProgress(1, 1)
            return@withContext results.distinctBy { it.url }
        }

        val hosts = (1..254).map { "$prefix.$it" }
        var checked = 0
        hosts.chunked(CONCURRENCY).forEach { chunk ->
            val found = coroutineScope {
                chunk.map { host ->
                    async {
                        // Port 8011 first: a hit there is the overwhelmingly likely case.
                        PORTS.firstNotNullOfOrNull { port ->
                            val url = "http://$host:$port"
                            if (Api.probe(url, PROBE_TIMEOUT_MS)) Found(url, host) else null
                        }
                    }
                }.awaitAll()
            }
            results += found.filterNotNull()
            checked += chunk.size
            onProgress(checked, hosts.size)
        }
        results.distinctBy { it.url }
    }

    /** "192.168.1" for a phone at 192.168.1.37 — the part every machine on the link shares. */
    private fun subnetPrefix(context: Context): String? {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return null
        val network = cm.activeNetwork ?: return null
        val props: LinkProperties = cm.getLinkProperties(network) ?: return null
        val address: InetAddress = props.linkAddresses
            .map { it.address }
            .firstOrNull { it is Inet4Address && !it.isLoopbackAddress }
            ?: return null
        return address.hostAddress?.substringBeforeLast('.')
    }
}
