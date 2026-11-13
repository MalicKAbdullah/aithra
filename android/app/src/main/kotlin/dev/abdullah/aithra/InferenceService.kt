package dev.abdullah.aithra

import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.IBinder
import android.os.Looper

/**
 * A foreground service held while the model loads or generates, so Android
 * neither freezes nor kills the process mid-reply or mid-calibration when
 * the user switches apps.
 */
class InferenceService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Thinking", NotificationManager.IMPORTANCE_LOW),
        )
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Aithra is thinking")
            .setOngoing(true)
            .build()
        startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        return START_NOT_STICKY
    }

    companion object {
        private const val CHANNEL = "inference"
        private const val ID = 1

        // Calibration is many engine jobs in a row; stopping between them
        // would need a restart, which Android refuses from the background.
        private const val LINGER_MS = 10_000L

        private val main = Handler(Looper.getMainLooper())
        private var holders = 0
        private var stopper: Runnable? = null

        /** Holds the service until the matching [release]. Any thread. */
        fun acquire(context: Context) = main.post {
            stopper?.let(main::removeCallbacks)
            stopper = null
            if (holders++ == 0) {
                try {
                    context.startForegroundService(Intent(context, InferenceService::class.java))
                } catch (_: ForegroundServiceStartNotAllowedException) {
                    // Work that begins while the app is already in the
                    // background (a calibration started by a finished
                    // download) cannot hold one; it runs as before.
                }
            }
        }

        fun release(context: Context) = main.post {
            if (--holders == 0) {
                stopper = Runnable { context.stopService(Intent(context, InferenceService::class.java)) }
                    .also { main.postDelayed(it, LINGER_MS) }
            }
        }
    }
}
