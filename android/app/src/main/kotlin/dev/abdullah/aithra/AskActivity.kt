package dev.abdullah.aithra

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivityLaunchConfigs.BackgroundMode
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * "Ask Aithra" in another app's text selection menu (PROCESS_TEXT): a
 * translucent sheet over that app, drawn by the `askMain` Dart entrypoint
 * in its own engine of the app's engine group.
 */
class AskActivity : FlutterFragmentActivity() {
    private val app get() = application as AithraApplication

    private val channels = NativeChannels(this, ::onCall)

    override fun onCreate(savedInstanceState: Bundle?) {
        app.surfaces++
        super.onCreate(savedInstanceState)
    }

    override fun getCachedEngineGroupId(): String = app.engineGroupId()

    override fun getDartEntrypointFunctionName() = "askMain"

    override fun getBackgroundMode() = BackgroundMode.transparent

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channels.attach(flutterEngine)
    }

    override fun onDestroy() {
        channels.destroy()
        app.surfaces--
        if (isFinishing && !isChangingConfigurations) app.releaseIfNoSurface()
        super.onDestroy()
    }

    private fun onCall(call: MethodCall, result: MethodChannel.Result): Boolean {
        when (call.method) {
            "ask.request" -> result.success(
                mapOf(
                    "text" to intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString().orEmpty(),
                    "readOnly" to intent.getBooleanExtra(Intent.EXTRA_PROCESS_TEXT_READONLY, false),
                ),
            )
            "ask.replace" -> {
                setResult(RESULT_OK, Intent().putExtra(Intent.EXTRA_PROCESS_TEXT, call.argument<String>("text")))
                result.success(null)
                finish()
            }
            "ask.close" -> {
                result.success(null)
                finish()
            }
            "ask.openChat" -> {
                startActivity(
                    Intent(this, MainActivity::class.java)
                        .putExtra(MainActivity.EXTRA_OPEN_CHAT, call.argument<String>("id"))
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                )
                result.success(null)
                finish()
            }
            else -> return false
        }
        return true
    }
}
