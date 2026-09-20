package com.worldbrief.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Re-arms the background refresh after a restart or an update; WorkManager forgets neither. */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_MY_PACKAGE_REPLACED ->
                RefreshWorker.schedule(context)
        }
    }
}
