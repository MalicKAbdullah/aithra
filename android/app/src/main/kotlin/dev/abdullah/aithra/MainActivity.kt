package dev.abdullah.aithra

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth
// (core_lock) and by the activity-result launchers in NativeChannels.
class MainActivity : FlutterFragmentActivity() {
    private val app get() = application as AithraApplication

    private val channels = NativeChannels(this, ::onCall)

    /**
     * What another app shared, or the chat the Ask sheet continues, until
     * Dart takes it (`inbox.take`): on a cold start Dart asks once it is
     * ready, on a warm one it is told by an `inbox` event.
     */
    private var inbox: Intent? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // A relaunch from recents replays the launching intent; it was handled.
        if (savedInstanceState == null) inbox = intent.takeIf(::isInbound)
        app.surfaces++
        super.onCreate(savedInstanceState)
    }

    override fun getCachedEngineGroupId(): String = app.engineGroupId()

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channels.attach(flutterEngine)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        if (isInbound(intent)) {
            inbox = intent
            channels.notify(mapOf("type" to "inbox"))
        }
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

    private fun isInbound(intent: Intent) =
        intent.action == Intent.ACTION_SEND || intent.action == Intent.ACTION_SEND_MULTIPLE ||
            intent.hasExtra(EXTRA_OPEN_CHAT)

    private fun onCall(call: MethodCall, result: MethodChannel.Result): Boolean {
        if (call.method != "inbox.take") return false
        val taken = inbox
        inbox = null
        if (taken == null) {
            result.success(null)
        } else {
            channels.onIo(result) { Inbox.read(taken, channels) }
        }
        return true
    }

    companion object {
        /** A conversation id to open, from the Ask sheet's Continue in chat. */
        const val EXTRA_OPEN_CHAT = "dev.abdullah.aithra.OPEN_CHAT"
    }
}

/** What a share or the Ask sheet hands the app, as Dart reads it. */
object Inbox {
    private const val MAX_SHARED_FILES = 10

    fun read(intent: Intent, channels: NativeChannels): Map<String, Any?> {
        intent.getStringExtra(MainActivity.EXTRA_OPEN_CHAT)?.let { return mapOf("kind" to "chat", "id" to it) }
        val uris = when (intent.action) {
            Intent.ACTION_SEND -> listOfNotNull(intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java))
            else -> intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java).orEmpty()
        }.take(MAX_SHARED_FILES)
        val images = ArrayList<ByteArray>()
        val documents = ArrayList<Map<String, Any?>>()
        val failures = ArrayList<String>()
        val activity = channels.activity
        for (uri in uris) {
            try {
                if (activity.contentResolver.getType(uri)?.startsWith("image/") == true) {
                    images += Media.normalizeImage(activity, uri)
                } else {
                    documents += channels.importDocument(uri)
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
            "documents" to documents,
            "failures" to failures,
        )
    }
}
