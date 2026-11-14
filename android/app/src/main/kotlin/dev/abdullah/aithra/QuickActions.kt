package dev.abdullah.aithra

import android.app.Activity
import android.app.ActivityManager
import android.app.PendingIntent
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService

/**
 * Launcher shortcuts and the Quick Settings tile. An action waits in
 * [pending] until Dart takes it (`quickAction.take`); Dart is told with a
 * `quickAction` event when it is already running, and takes it at startup
 * otherwise.
 */
object QuickActions {
    private const val PREFIX = "dev.abdullah.aithra.action."
    const val VOICE_MODE = PREFIX + "VOICE_MODE"

    /** Intent actions to the names Dart knows them by. */
    private val names = mapOf(
        PREFIX + "NEW_CHAT" to "newChat",
        VOICE_MODE to "voiceMode",
        PREFIX + "ASK_PHOTO" to "askPhoto",
        PREFIX + "VOICE_NOTE" to "voiceNote",
    )

    @Volatile private var pending: String? = null

    /** Holds [intent]'s action for Dart; false when it is not one. */
    fun offer(intent: Intent?): Boolean {
        val name = names[intent?.action] ?: return false
        pending = name
        Events.send(mapOf("type" to "quickAction"))
        return true
    }

    fun take(): String? = pending.also { pending = null }
}

/**
 * Where shortcuts and the tile land. Android starts a static shortcut with
 * FLAG_ACTIVITY_CLEAR_TASK, which would finish MainActivity, end its
 * Flutter engine and unload the model; this activity sits in its own task,
 * so that flag clears only itself. It brings Aithra's task forward with
 * the action waiting, or starts Aithra with it.
 */
class QuickActionActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val main = getSystemService(ActivityManager::class.java).appTasks.firstOrNull {
            it.taskInfo.baseActivity?.className == MainActivity::class.java.name
        }
        if (main != null && QuickActions.offer(intent)) {
            main.moveToFront()
        } else {
            startActivity(
                Intent(this, MainActivity::class.java)
                    .setAction(intent.action)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
        finish()
    }
}

/** A Quick Settings tile that opens voice mode. */
class VoiceTileService : TileService() {
    override fun onStartListening() {
        super.onStartListening()
        val tile = qsTile ?: return
        tile.state = Tile.STATE_INACTIVE
        tile.updateTile()
    }

    override fun onClick() {
        super.onClick()
        if (isLocked) unlockAndRun(::open) else open()
    }

    private fun open() {
        val intent = Intent(this, QuickActionActivity::class.java)
            .setAction(QuickActions.VOICE_MODE)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startActivityAndCollapse(
                PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE),
            )
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }
}
