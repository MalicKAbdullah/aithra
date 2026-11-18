package dev.abdullah.aithra

import android.app.Activity
import android.app.ActivityManager
import android.app.ForegroundServiceStartNotAllowedException
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Bundle
import android.os.IBinder
import android.util.Log

/**
 * The foreground service that keeps the process running while the user is
 * away from Aithra and a reply they asked for is still being written (see
 * [Replies]). It shows "Aithra is replying…" with a Stop action.
 */
class InferenceService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            Events.send(mapOf("type" to "reply", "kind" to "stop"))
            // A tap that outlived the service created it anew; that one
            // has nothing to keep running.
            if (state != State.RUNNING) stopSelf(startId)
            return START_NOT_STICKY
        }
        startForeground(ID, notification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        state = State.RUNNING
        if (stopWhenStarted) stop(this)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        if (state == State.RUNNING) state = State.STOPPED
        super.onDestroy()
    }

    private fun notification(): Notification {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Reply in progress", NotificationManager.IMPORTANCE_LOW),
        )
        val stop = PendingIntent.getService(
            this,
            1,
            Intent(this, InferenceService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Aithra is replying…")
            .setContentIntent(ReplyNotifications.openApp(this))
            .addAction(Notification.Action.Builder(null, "Stop", stop).build())
            .setOngoing(true)
            .build()
    }

    private enum class State { STOPPED, STARTING, RUNNING }

    companion object {
        private const val TAG = "aithra.replies"
        private const val CHANNEL = "inference"
        private const val ID = 1
        private const val ACTION_STOP = "dev.abdullah.aithra.STOP_GENERATION"

        // Main thread, like every call into this object.
        private var state = State.STOPPED

        // Stopping a service that has not yet called startForeground kills
        // the app, so a stop that comes first waits for onStartCommand.
        private var stopWhenStarted = false

        fun start(context: Context) {
            stopWhenStarted = false
            if (state != State.STOPPED) return
            try {
                context.startForegroundService(Intent(context, InferenceService::class.java))
                state = State.STARTING
                Log.i(TAG, "foreground service started")
            } catch (e: ForegroundServiceStartNotAllowedException) {
                // Replies start the service while an activity is visible or
                // within Android's grace period after the last one stops;
                // reaching this means a reply began with the app already in
                // the background, which nothing in the app does.
                Log.e(TAG, "Android refused to start the foreground service", e)
            }
        }

        fun stop(context: Context) {
            when (state) {
                State.STOPPED -> Unit
                State.STARTING -> stopWhenStarted = true
                State.RUNNING -> {
                    stopWhenStarted = false
                    state = State.STOPPED
                    context.stopService(Intent(context, InferenceService::class.java))
                    Log.i(TAG, "foreground service stopped")
                }
            }
        }
    }
}

/** The "Reply ready" notifications of replies that ended while the user was away. */
object ReplyNotifications {
    private const val CHANNEL = "replies"
    private const val ID = 3
    private const val EXTRA_CHAT = "dev.abdullah.aithra.CHAT"
    private const val EXTRA_TASK = "dev.abdullah.aithra.TASK"

    // Chat ids are numbers, so no chat's tag starts with this.
    private const val ASK_PREFIX = "ask-"

    fun openApp(context: Context): PendingIntent = PendingIntent.getActivity(
        context,
        0,
        Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
        PendingIntent.FLAG_IMMUTABLE,
    )

    fun post(context: Context, note: Replies.ReadyNote) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Replies ready", NotificationManager.IMPORTANCE_DEFAULT),
        )
        val tag = note.chat ?: askTag(note.askTask)
        val open = if (note.chat != null) {
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
                .putExtra(EXTRA_CHAT, note.chat)
        } else {
            Intent(context, ReturnActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                .putExtra(EXTRA_TASK, note.askTask)
        }
        val notification = Notification.Builder(context, CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle("Reply ready")
            .setContentText(note.title)
            .setContentIntent(
                PendingIntent.getActivity(
                    context,
                    tag.hashCode(),
                    open,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
            .setAutoCancel(true)
            .build()
        manager.notify(tag, ID, notification)
        Log.i("aithra.replies", "reply ready posted")
    }

    /** Clears every chat's "Reply ready": the app is showing. */
    fun clearChats(context: Context) {
        val manager = context.getSystemService(NotificationManager::class.java)
        for (n in manager.activeNotifications) {
            if (n.notification.channelId == CHANNEL && !n.tag.startsWith(ASK_PREFIX)) manager.cancel(n.tag, ID)
        }
    }

    /** Clears the "Reply ready" of the Ask sheet in [task]: it is showing. */
    fun clearAsk(context: Context, task: Int) =
        context.getSystemService(NotificationManager::class.java).cancel(askTag(task), ID)

    private fun askTag(task: Int) = "$ASK_PREFIX$task"

    /** The chat a "Reply ready" tap opens, if [intent] is one. */
    fun chatOf(intent: Intent): String? = intent.getStringExtra(EXTRA_CHAT)

    /** The task of the Ask sheet a "Reply ready" tap returns to. */
    fun taskOf(intent: Intent): Int {
        check(intent.hasExtra(EXTRA_TASK)) { "ReturnActivity is started by a Reply ready notification" }
        return intent.getIntExtra(EXTRA_TASK, 0)
    }
}

/**
 * Where tapping the Ask sheet's "Reply ready" lands. The sheet lives in the
 * task of the app whose text it was asked about, which Aithra cannot start
 * an activity into; this one brings that task forward and goes.
 */
class ReturnActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        getSystemService(ActivityManager::class.java).moveTaskToFront(ReplyNotifications.taskOf(intent), 0)
        finish()
    }
}
