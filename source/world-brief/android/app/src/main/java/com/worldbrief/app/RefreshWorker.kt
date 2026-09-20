package com.worldbrief.app

import android.content.Context
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import java.util.concurrent.TimeUnit

/**
 * Keeps a copy of the brief on the phone.
 *
 * The heavy work — fetching several hundred feeds, clustering them, ranking what matters — runs
 * on the machine World Brief is installed on. This worker only collects the result, so the app
 * opens instantly and still has something to read with no signal.
 */
class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        val prefs = Prefs(applicationContext)
        if (!prefs.isConfigured || !prefs.backgroundRefresh) return Result.success()

        val base = prefs.serverUrl
        return try {
            if (!Api.probe(base)) return Result.retry()

            val brief = Api.fetchBrief(base)
            val cache = BriefCache(applicationContext)
            cache.save(brief)
            prefs.lastSyncMillis = System.currentTimeMillis()

            val cached = cache.load() ?: return Result.success()
            val built = cached.builtAt
            if (prefs.notify && built > 0 && built != prefs.lastBriefBuilt) {
                val first = prefs.lastBriefBuilt == 0L
                prefs.lastBriefBuilt = built
                val minutes = brief.optJSONObject("meta")?.optInt("brief_minutes", 15) ?: 15
                if (!first) Notifications.briefReady(applicationContext, cached.eventCount, minutes)
            }
            Result.success()
        } catch (_: Exception) {
            Result.retry()
        }
    }

    companion object {
        private const val NAME = "world-brief-refresh"

        fun schedule(context: Context) {
            val prefs = Prefs(context)
            val manager = WorkManager.getInstance(context)
            if (!prefs.isConfigured || !prefs.backgroundRefresh) {
                manager.cancelUniqueWork(NAME)
                return
            }
            val request = PeriodicWorkRequestBuilder<RefreshWorker>(
                prefs.refreshMinutes.toLong(), TimeUnit.MINUTES,
            )
                .setConstraints(
                    Constraints.Builder()
                        .setRequiredNetworkType(NetworkType.CONNECTED)
                        .build(),
                )
                .setBackoffCriteria(androidx.work.BackoffPolicy.LINEAR, 10, TimeUnit.MINUTES)
                .build()
            manager.enqueueUniquePeriodicWork(NAME, ExistingPeriodicWorkPolicy.UPDATE, request)
        }

        fun cancel(context: Context) {
            WorkManager.getInstance(context).cancelUniqueWork(NAME)
        }
    }
}
