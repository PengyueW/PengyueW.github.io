package com.worldbrief.app

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL

/**
 * The handful of calls the phone makes to a World Brief server. Deliberately plain
 * HttpURLConnection: a news reader does not need a networking framework.
 */
object Api {

    private const val CONNECT_TIMEOUT = 4000
    private const val READ_TIMEOUT = 20000
    const val USER_AGENT = "WorldBrief-Android"

    private fun open(url: String, timeout: Int): HttpURLConnection =
        (URL(url).openConnection() as HttpURLConnection).apply {
            connectTimeout = timeout
            readTimeout = READ_TIMEOUT
            requestMethod = "GET"
            setRequestProperty("User-Agent", USER_AGENT)
            setRequestProperty("Accept", "application/json")
        }

    private fun getJson(url: String, timeout: Int = CONNECT_TIMEOUT): JSONObject {
        val conn = open(url, timeout)
        try {
            if (conn.responseCode != 200) throw IOException("HTTP ${conn.responseCode}")
            return JSONObject(conn.inputStream.bufferedReader().use { it.readText() })
        } finally {
            conn.disconnect()
        }
    }

    /** True when something that answers like World Brief is listening at [base]. */
    suspend fun probe(base: String, timeoutMs: Int = CONNECT_TIMEOUT): Boolean =
        withContext(Dispatchers.IO) {
            try {
                val json = getJson("$base/api/status", timeoutMs)
                json.has("pipeline") && json.has("refresh_minutes")
            } catch (_: Exception) {
                false
            }
        }

    /** The current brief, as the server's own /api/events?brief=true returns it. */
    suspend fun fetchBrief(base: String, limit: Int = 40): JSONObject =
        withContext(Dispatchers.IO) {
            getJson("$base/api/events?brief=true&limit=$limit", CONNECT_TIMEOUT * 2)
        }

    suspend fun fetchStatus(base: String): JSONObject =
        withContext(Dispatchers.IO) { getJson("$base/api/status") }

    /** Asks the server to start a refresh now. Returns false when it declines or is unreachable. */
    suspend fun requestRefresh(base: String): Boolean = withContext(Dispatchers.IO) {
        val conn = (URL("$base/api/refresh").openConnection() as HttpURLConnection).apply {
            connectTimeout = CONNECT_TIMEOUT
            readTimeout = READ_TIMEOUT
            requestMethod = "POST"
            setRequestProperty("User-Agent", USER_AGENT)
            setRequestProperty("Content-Length", "0")
            doOutput = true
        }
        try {
            conn.outputStream.close()
            conn.responseCode == 200
        } catch (_: Exception) {
            false
        } finally {
            conn.disconnect()
        }
    }
}
