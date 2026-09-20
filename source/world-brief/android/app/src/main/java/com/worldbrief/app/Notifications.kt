package com.worldbrief.app

import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

object Notifications {

    const val CHANNEL_BRIEF = "brief"
    private const val ID_BRIEF = 1001

    fun createChannels(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_BRIEF,
            context.getString(R.string.channel_brief_name),
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = context.getString(R.string.channel_brief_description)
            setShowBadge(true)
        }
        context.getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
    }

    /** "Your brief is ready" — tapping it opens the app straight on the brief. */
    fun briefReady(context: Context, eventCount: Int, minutes: Int) {
        val manager = NotificationManagerCompat.from(context)
        if (!manager.areNotificationsEnabled()) return

        val intent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP
        }
        val pending = PendingIntent.getActivity(
            context, 0, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        val text = context.resources.getQuantityString(
            R.plurals.notification_brief_body, eventCount, eventCount, minutes,
        )
        val notification = NotificationCompat.Builder(context, CHANNEL_BRIEF)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(context.getString(R.string.notification_brief_title))
            .setContentText(text)
            .setStyle(NotificationCompat.BigTextStyle().bigText(text))
            .setPriority(NotificationCompat.PRIORITY_DEFAULT)
            .setCategory(NotificationCompat.CATEGORY_RECOMMENDATION)
            .setContentIntent(pending)
            .setAutoCancel(true)
            .build()
        try {
            manager.notify(ID_BRIEF, notification)
        } catch (_: SecurityException) {
            // POST_NOTIFICATIONS was refused; the brief is cached either way.
        }
    }
}
