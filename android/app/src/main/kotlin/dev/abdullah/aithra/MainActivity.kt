package dev.abdullah.aithra

import android.app.Activity
import android.app.ActivityManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import java.io.File
import java.util.UUID
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth
// (core_lock) and by the activity-result launchers in NativeChannels.
class MainActivity : FlutterFragmentActivity() {
    private val app get() = application as AithraApplication

    private val channels = NativeChannels(this)

    override fun onCreate(savedInstanceState: Bundle?) {
        app.surfaces++
        super.onCreate(savedInstanceState)
        // Started by QuickActionActivity with no task to bring forward. A
        // relaunch from Recents carries the same intent and must not
        // repeat it.
        if (savedInstanceState == null && intent.flags and Intent.FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY == 0) {
            QuickActions.offer(intent)
        }
    }

    override fun getCachedEngineGroupId(): String = app.engineGroupId()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channels.attach(flutterEngine)
    }

    // From onResume, when the activity is visible: Android lets a visible
    // app start the download's foreground service.
    override fun onResume() {
        super.onResume()
        app.io.execute { ModelDownloads.resume(this) }
    }

    override fun onDestroy() {
        channels.destroy()
        app.surfaces--
        // Swiped from recents (or otherwise finished): the Flutter engine,
        // and with it the timer that frees the model after a while in the
        // background, ends with this activity, while the process can live
        // on with the model loaded, under a lingering foreground service or
        // on an Android that keeps it cached.
        if (isFinishing && !isChangingConfigurations) app.releaseIfNoSurface()
        super.onDestroy()
    }
}

/**
 * What another app shared, or the chat the Ask sheet continues, until Dart
 * takes it (`inbox.take`). Dart is told with an `inbox` event when it is
 * running and takes it at startup otherwise.
 */
object Inbox {
    private const val MAX_SHARED_FILES = 10

    @Volatile private var pending: Map<String, Any?>? = null

    fun sharedDir(context: Context) = File(context.cacheDir, "inbox").apply { mkdirs() }

    fun take(): Map<String, Any?>? = pending.also { pending = null }

    /** Holds [item] for the app and brings the app forward, or starts it. */
    fun deliver(context: Context, item: Map<String, Any?>) {
        pending = item
        Events.send(mapOf("type" to "inbox"))
        val task = context.getSystemService(ActivityManager::class.java).appTasks.firstOrNull {
            it.taskInfo.baseActivity?.className == MainActivity::class.java.name
        }
        if (task != null) {
            task.moveToFront()
        } else {
            context.startActivity(Intent(context, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
        }
    }

    /**
     * Reads a share: images downsized, other files copied into the cache
     * for the app to read as documents (`doc.importShared`) once it has
     * opened the database, which may not have happened yet.
     */
    fun read(context: Context, intent: Intent): Map<String, Any?> {
        val uris = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java))
            else -> intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
        }.take(MAX_SHARED_FILES)
        val images = ArrayList<ByteArray>()
        val files = ArrayList<Map<String, Any?>>()
        val failures = ArrayList<String>()
        for (uri in uris) {
            try {
                if (context.contentResolver.getType(uri)?.startsWith("image/") == true) {
                    images += Media.normalizeImage(context, uri)
                } else {
                    val copy = File(sharedDir(context), UUID.randomUUID().toString())
                    context.contentResolver.openInputStream(uri)!!.use { input -> copy.outputStream().use { input.copyTo(it) } }
                    files += mapOf(
                        "path" to copy.path,
                        "name" to Media.displayName(context, uri),
                        "mime" to context.contentResolver.getType(uri),
                    )
                }
            } catch (e: Exception) {
                failures += e.message ?: e.javaClass.simpleName
            }
        }
        return mapOf(
            "kind" to "share",
            "text" to intent.getStringExtra(Intent.EXTRA_TEXT),
            "subject" to intent.getStringExtra(Intent.EXTRA_SUBJECT),
            "images" to images,
            "files" to files,
            "failures" to failures,
        )
    }
}

/**
 * Where shares from other apps land. In its own task, so the share never
 * starts a second copy of the app (and of its Flutter engine) inside the
 * sharing app's task. It reads what was shared while it holds the read
 * grant for it, then hands it to the app's task.
 */
class ShareActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val app = application as AithraApplication
        app.io.execute {
            val item = Inbox.read(this, intent)
            runOnUiThread {
                Inbox.deliver(this, item)
                finish()
            }
        }
    }
}
