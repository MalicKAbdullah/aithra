package dev.abdullah.aithra

import android.app.Application

class AithraApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        CrashLog.install(this)
    }
}
