package dev.abdullah.aithra

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Bundle
import android.provider.Settings
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import dev.abdullah.aithra.engine.ChatTurn
import dev.abdullah.aithra.engine.CpuFeatures
import dev.abdullah.aithra.engine.Embedder
import dev.abdullah.aithra.engine.EngineHost
import dev.abdullah.aithra.engine.GenerateRequest
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executor
import java.util.concurrent.Executors

// FlutterFragmentActivity (not FlutterActivity) is required by local_auth
// (core_lock) and by the activity-result launchers below.
class MainActivity : FlutterFragmentActivity() {
    private val app get() = application as AithraApplication
    private val engineHost get() = app.engineHost
    private val db get() = app.db
    private val embedder get() = app.embedder
    private val io get() = app.io

    private lateinit var speech: SpeechBridge
    private lateinit var tts: TtsBridge

    private lateinit var pickImage: ActivityResultLauncher<PickVisualMediaRequest>
    private lateinit var takePicture: ActivityResultLauncher<Uri>
    private lateinit var pickModel: ActivityResultLauncher<Array<String>>
    private lateinit var askPermission: ActivityResultLauncher<String>
    private lateinit var askNotifications: ActivityResultLauncher<String>

    // One request of each kind can be open at a time: each launcher has one
    // result slot.
    private var pendingImage: MethodChannel.Result? = null
    private var pendingModel: MethodChannel.Result? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var captureFile: File? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Created before super.onCreate, which attaches the Flutter engine
        // (configureFlutterEngine), so every callback that uses them, such
        // as onDestroy, finds them set.
        speech = SpeechBridge(this)
        tts = TtsBridge(this)
        super.onCreate(savedInstanceState)
        pickImage = registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri ->
            deliverImage(uri)
        }
        takePicture = registerForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
            val file = captureFile
            deliverImage(if (ok && file != null) Uri.fromFile(file) else null)
        }
        pickModel = registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            val result = pendingModel ?: return@registerForActivityResult
            pendingModel = null
            if (uri == null) {
                result.success(null)
                return@registerForActivityResult
            }
            onIo(result) { Media.importModel(this, uri) }
        }
        // Downloads run the same either way; the answer only decides whether
        // their progress notification shows.
        askNotifications = registerForActivityResult(ActivityResultContracts.RequestPermission()) {}
        askPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            pendingPermission?.success(microphoneState(granted))
            pendingPermission = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, "aithra/events").setStreamHandler(Events)
        MethodChannel(messenger, "aithra/native").setMethodCallHandler(::onCall)
    }

    // From onResume, when the activity is visible: Android lets a visible
    // app start the download's foreground service.
    override fun onResume() {
        super.onResume()
        app.io.execute { ModelDownloads.resume(this) }
    }

    override fun onDestroy() {
        speech.destroy()
        tts.shutdown()
        super.onDestroy()
    }

    /**
     * After a denial Android shows the rationale flag only while asking
     * again can still show the dialog; without it the denial is permanent
     * and only Settings can grant the microphone.
     */
    private fun microphoneState(granted: Boolean) = when {
        granted -> "granted"
        shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) -> "denied"
        else -> "blocked"
    }

    /** Claims [slot] for [result], or answers `busy` when it is taken. */
    private inline fun claim(slot: MethodChannel.Result?, result: MethodChannel.Result, launch: () -> Unit) {
        if (slot != null) {
            result.error("busy", "Another request of this kind is still open", null)
        } else {
            launch()
        }
    }

    private fun deliverImage(uri: Uri?) {
        val result = pendingImage ?: return
        pendingImage = null
        if (uri == null) {
            result.success(null)
            return
        }
        val capture = captureFile
        captureFile = null
        runOn(io, "image", result) {
            try {
                Media.normalizeImage(this, uri)
            } finally {
                capture?.delete()
            }
        }
    }

    private fun <T> onEngine(result: MethodChannel.Result, block: () -> T) =
        engineHost.submit(block) { reply(result, "engine", it) }

    /** Engine work that keeps the process in the foreground while it runs. */
    private fun <T> onEngineHeld(result: MethodChannel.Result, block: () -> T) =
        engineHost.submitHeld(block) { reply(result, "engine", it) }

    private fun <T> onIo(result: MethodChannel.Result, block: () -> T) = runOn(io, "io", result, block)

    private fun <T> onDb(result: MethodChannel.Result, block: () -> T) = runOn(app.dbExec, "db", result, block)

    private fun <T> onEmbed(result: MethodChannel.Result, block: () -> T) = runOn(app.embedExec, "embed", result, block)

    private fun <T> runOn(executor: Executor, code: String, result: MethodChannel.Result, block: () -> T) =
        executor.execute { reply(result, code, runCatching(block)) }

    /**
     * The one place a background outcome reaches the channel. A Kotlin
     * function with no return value yields [Unit], which StandardMessageCodec
     * cannot encode (it throws on the main thread and kills the process), so
     * it is sent as null, the channel's void.
     */
    private fun <T> reply(result: MethodChannel.Result, code: String, outcome: Result<T>) = runOnUiThread {
        outcome.fold(
            { result.success(if (it is Unit) null else it) },
            { result.error(code, it.message ?: it.javaClass.simpleName, null) },
        )
    }

    private fun startDownload(call: MethodCall, result: MethodChannel.Result) = onIo(result) {
        ModelDownloads.start(
            this,
            call.argument<String>("url")!!,
            call.argument<String>("fileName")!!,
            call.argument<String>("title")!!,
            call.argument<Number>("size")!!.toLong(),
            call.argument<String>("sha256")!!,
        )
    }

    @Suppress("UNCHECKED_CAST")
    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "engine.load" -> onEngineHeld(result) { engineHost.load(call.arguments as Map<String, Any?>) }
            "engine.generate" -> {
                val requestId = call.argument<Int>("requestId")!!
                val turns = (call.argument<List<Map<String, Any?>>>("turns")!!).map {
                    ChatTurn(
                        role = it["role"] as String,
                        text = it["text"] as String,
                        images = (it["images"] as List<ByteArray>?) ?: emptyList(),
                    )
                }
                val request = GenerateRequest(
                    turns = turns,
                    maxTokens = call.argument<Int>("maxTokens")!!,
                    temperature = call.argument<Double>("temperature")!!.toFloat(),
                    ignoreEos = call.argument<Boolean>("ignoreEos")!!,
                )
                engineHost.enqueue(requestId)
                onEngineHeld(result) {
                    engineHost.generate(requestId, request) { text ->
                        Events.send(mapOf("type" to "token", "requestId" to requestId, "text" to text))
                        true
                    }
                }
            }
            "engine.countTokens" -> {
                val turns = (call.argument<List<Map<String, Any?>>>("turns")!!).map {
                    ChatTurn(role = it["role"] as String, text = it["text"] as String, images = emptyList())
                }
                onEngine(result) { engineHost.countTokens(turns) }
            }
            "engine.cancel" -> {
                engineHost.cancel(call.argument<Int>("requestId")!!)
                result.success(null)
            }
            "engine.unload" -> onEngine(result) { engineHost.unload() }

            "db.open" -> onDb(result) { db.open(call.argument<ByteArray>("key")!!) }
            "db.conversations" -> onDb(result) {
                db.listConversations(call.argument<Int>("offset")!!, call.argument<Int>("limit")!!)
            }
            "db.conversation" -> onDb(result) { db.getConversation(call.argument<String>("id")!!) }
            "db.createConversation" -> onDb(result) {
                db.createConversation(call.argument<String>("id")!!, call.argument<String>("title")!!, call.argument<Number>("now")!!.toLong())
            }
            "db.updateConversation" -> onDb(result) {
                db.updateConversation(call.argument<String>("id")!!, call.argument<Map<String, Any?>>("fields")!!)
            }
            "db.deleteConversation" -> onDb(result) { db.deleteConversation(call.argument<String>("id")!!) }
            "db.messages" -> onDb(result) {
                db.messages(call.argument<String>("convId")!!, call.argument<Int>("beforeSeq")!!, call.argument<Int>("limit")!!)
            }
            "db.messageRange" -> onDb(result) {
                db.messageRange(call.argument<String>("convId")!!, call.argument<Int>("fromSeq")!!, call.argument<Int>("toSeq")!!)
            }
            "db.addMessage" -> onDb(result) {
                db.addMessage(
                    call.argument<String>("convId")!!,
                    call.argument<String>("role")!!,
                    call.argument<String>("content")!!,
                    call.argument<List<String>>("images")!!,
                    call.argument<String>("stats"),
                    call.argument<Number>("now")!!.toLong(),
                )
            }
            "db.updateMessage" -> onDb(result) {
                db.updateMessage(call.argument<Number>("id")!!.toLong(), call.argument<String>("content")!!, call.argument<String>("stats"))
            }
            "db.setTokens" -> onDb(result) {
                val counts = (call.argument<Map<String, Int>>("counts")!!).mapKeys { it.key.toLong() }
                db.setTokens(counts, call.argument<String>("model")!!)
            }
            "db.truncate" -> onDb(result) {
                db.truncate(
                    call.argument<String>("convId")!!,
                    call.argument<Int>("fromSeq")!!,
                    call.argument<List<String>>("keepImages")!!.toSet(),
                )
            }
            "db.putImage" -> onDb(result) {
                val jpeg = call.argument<ByteArray>("jpeg")!!
                db.putImage(call.argument<String>("id")!!, jpeg, Media.thumbnail(jpeg))
            }
            "db.image" -> onDb(result) { db.image(call.argument<String>("id")!!, call.argument<Boolean>("thumb")!!) }
            "db.search" -> onDb(result) { db.search(call.argument<String>("query")!!, call.argument<Int>("limit")!!) }
            "db.recall" -> onEmbed(result) {
                db.recall(
                    embedder,
                    call.argument<String>("modelPath")!!,
                    call.argument<String>("query")!!,
                    call.argument<String>("excludeConv"),
                    call.argument<Int>("limit")!!,
                )
            }
            "db.searchMessages" -> onEmbed(result) {
                db.searchMessages(
                    embedder,
                    call.argument<String>("modelPath")!!,
                    call.argument<String>("query")!!,
                    call.argument<Int>("limit")!!,
                )
            }
            "db.vectorStatus" -> onDb(result) { db.vectorStatus() }
            "db.indexVectors" -> onEmbed(result) {
                db.indexVectors(embedder, call.argument<String>("modelPath")!!, call.argument<Int>("limit")!!)
            }
            "db.selfTest" -> onDb(result) { db.selfTest(call.argument<Int>("messages")!!) }

            "device.info" -> onIo(result) { DeviceInfo.collect(this) }
            "device.runsLlama" -> result.success(CpuFeatures.runsLlama)

            "crash.read" -> result.success(CrashLog.read(this))
            "crash.record" -> onIo(result) {
                CrashLog.record(this, call.argument<String>("title")!!, call.argument<String>("detail")!!)
            }
            "crash.clear" -> onIo(result) { CrashLog.clear(this) }

            // Internal storage: always present, so startup never depends on
            // shared storage being mounted.
            "storage.dataDir" -> result.success(filesDir.path)
            "storage.info" -> onIo(result) { Storage.info(this) }
            "storage.hasData" -> onIo(result) { Storage.hasData(this) }
            "storage.erase" -> onIo(result) { Storage.erase(this) }

            "download.start" -> {
                if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                    askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
                startDownload(call, result)
            }
            "download.query" -> onIo(result) { ModelDownloads.query(this) }
            "download.remove" -> onIo(result) { ModelDownloads.remove(this, (call.argument<Number>("id")!!).toLong()) }
            "file.delete" -> onIo(result) { File(call.argument<String>("path")!!).delete() }
            // Complete files only, named relative to the models folder
            // ("imported/x.gguf" for imports).
            "file.list" -> onIo(result) {
                val root = modelsDir(this)
                root.walk()
                    .filter {
                        it.isFile && !it.name.endsWith(Media.PARTIAL_SUFFIX) &&
                            !it.name.endsWith(ModelDownloads.PART_SUFFIX)
                    }
                    .map { mapOf("path" to it.path, "name" to it.relativeTo(root).path, "size" to it.length()) }
                    .toList()
            }

            // Model files have no registered MIME type; Media.importModel
            // checks the extension.
            "import.model" -> claim(pendingModel, result) {
                pendingModel = result
                pickModel.launch(arrayOf("*/*"))
            }
            "media.pickImage" -> claim(pendingImage, result) {
                pendingImage = result
                pickImage.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            }
            "media.capture" -> claim(pendingImage, result) {
                pendingImage = result
                val file = File(cacheDir, "capture/photo.jpg").apply { parentFile!!.mkdirs() }
                captureFile = file
                takePicture.launch(FileProvider.getUriForFile(this, "$packageName.files", file))
            }
            "share.text" -> {
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, call.argument<String>("text"))
                }
                startActivity(Intent.createChooser(send, null))
                result.success(null)
            }

            "permission.microphone" -> {
                if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                    result.success("granted")
                } else {
                    claim(pendingPermission, result) {
                        pendingPermission = result
                        askPermission.launch(Manifest.permission.RECORD_AUDIO)
                    }
                }
            }
            "permission.openSettings" -> {
                startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", packageName, null)),
                )
                result.success(null)
            }
            "speech.status" -> {
                if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                    speech.prewarm()
                }
                speech.status { result.success(it) }
            }
            "speech.start" -> {
                speech.start(call.argument<Boolean>("continuous")!!)
                result.success(null)
            }
            "speech.stop" -> {
                speech.stop()
                result.success(null)
            }
            "speech.cancel" -> {
                speech.cancel()
                result.success(null)
            }
            "speech.downloadModel" -> result.success(speech.downloadModel())
            "speech.openSettings" -> {
                startActivity(speech.settingsIntent())
                result.success(null)
            }
            "tts.speak" -> {
                tts.speak(call.argument<String>("text")!!, call.argument<String>("id")!!)
                result.success(null)
            }
            "tts.stop" -> {
                tts.stop()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
