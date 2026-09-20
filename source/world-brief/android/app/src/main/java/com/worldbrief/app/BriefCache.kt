package com.worldbrief.app

import android.content.Context
import org.json.JSONObject
import java.io.File

/**
 * The last brief fetched, kept on disk so the app has something to show on a train with no
 * signal, or while the desktop machine is asleep.
 */
class BriefCache(context: Context) {

    private val file = File(context.applicationContext.filesDir, FILE_NAME)

    fun save(payload: JSONObject) {
        val wrapped = JSONObject().apply {
            put("fetched_at", System.currentTimeMillis())
            put("payload", payload)
        }
        val tmp = File(file.parentFile, "$FILE_NAME.tmp")
        tmp.writeText(wrapped.toString())
        tmp.renameTo(file)
    }

    fun load(): Cached? {
        if (!file.exists()) return null
        return try {
            val wrapped = JSONObject(file.readText())
            Cached(wrapped.getLong("fetched_at"), wrapped.getJSONObject("payload"))
        } catch (_: Exception) {
            null
        }
    }

    fun clear() {
        file.delete()
    }

    data class Cached(val fetchedAt: Long, val payload: JSONObject) {
        val eventCount: Int get() = payload.optJSONArray("events")?.length() ?: 0

        /** When the server generated this brief, as epoch seconds; 0 when it did not say. */
        val builtAt: Long
            get() = payload.optJSONObject("meta")?.optDouble("generated_at", 0.0)?.toLong() ?: 0L
    }

    companion object {
        private const val FILE_NAME = "brief-cache.json"
    }
}
