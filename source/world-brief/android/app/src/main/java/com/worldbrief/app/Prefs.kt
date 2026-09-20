package com.worldbrief.app

import android.content.Context
import android.content.SharedPreferences

/** Everything the app remembers between launches: where the brief comes from, and what it last saw. */
class Prefs(context: Context) {

    private val sp: SharedPreferences =
        context.applicationContext.getSharedPreferences(FILE, Context.MODE_PRIVATE)

    /** Base address of the World Brief server, e.g. "http://192.168.1.20:8011". Empty until set up. */
    var serverUrl: String
        get() = sp.getString(KEY_SERVER, "").orEmpty()
        set(value) = sp.edit().putString(KEY_SERVER, normalise(value)).apply()

    /** Refresh the cached brief in the background, and say so when a new one arrives. */
    var backgroundRefresh: Boolean
        get() = sp.getBoolean(KEY_BACKGROUND, true)
        set(value) = sp.edit().putBoolean(KEY_BACKGROUND, value).apply()

    var notify: Boolean
        get() = sp.getBoolean(KEY_NOTIFY, true)
        set(value) = sp.edit().putBoolean(KEY_NOTIFY, value).apply()

    /** How often the background worker looks for a new brief, in minutes. */
    var refreshMinutes: Int
        get() = sp.getInt(KEY_INTERVAL, 60)
        set(value) = sp.edit().putInt(KEY_INTERVAL, value.coerceIn(15, 24 * 60)).apply()

    /** "built" timestamp of the newest brief already shown, so the same one is announced once. */
    var lastBriefBuilt: Long
        get() = sp.getLong(KEY_LAST_BRIEF, 0L)
        set(value) = sp.edit().putLong(KEY_LAST_BRIEF, value).apply()

    var lastSyncMillis: Long
        get() = sp.getLong(KEY_LAST_SYNC, 0L)
        set(value) = sp.edit().putLong(KEY_LAST_SYNC, value).apply()

    val isConfigured: Boolean get() = serverUrl.isNotEmpty()

    companion object {
        private const val FILE = "worldbrief"
        private const val KEY_SERVER = "server_url"
        private const val KEY_BACKGROUND = "background_refresh"
        private const val KEY_NOTIFY = "notify"
        private const val KEY_INTERVAL = "refresh_minutes"
        private const val KEY_LAST_BRIEF = "last_brief_built"
        private const val KEY_LAST_SYNC = "last_sync"

        /** Accepts "192.168.1.20", "host:8011" or a full URL, and returns a usable base address. */
        fun normalise(raw: String): String {
            var s = raw.trim().trimEnd('/')
            if (s.isEmpty()) return ""
            if (!s.startsWith("http://") && !s.startsWith("https://")) s = "http://$s"
            val afterScheme = s.substringAfter("://")
            if (!afterScheme.contains(':') && !afterScheme.contains('/')) s = "$s:8011"
            return s
        }
    }
}
