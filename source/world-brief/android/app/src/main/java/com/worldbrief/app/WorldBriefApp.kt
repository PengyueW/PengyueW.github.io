package com.worldbrief.app

import android.app.Application

class WorldBriefApp : Application() {
    override fun onCreate() {
        super.onCreate()
        Notifications.createChannels(this)
        RefreshWorker.schedule(this)
    }
}
