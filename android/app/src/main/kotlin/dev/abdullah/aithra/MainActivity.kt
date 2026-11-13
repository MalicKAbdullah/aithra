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
    private lateinit var engineHost: EngineHost
    private lateinit var speech: SpeechBridge
    private lateinit var tts: TtsBridge
    private lateinit var db: ChatDb
    private val io = Executors.newSingleThreadExecutor { r -> Thread(r, "aithra-io") }
    private val dbExec = Executors.newSingleThreadExecutor { r -> Thread(r, "aithra-db") }

    // Embedding runs off the db thread so chat-list and message reads never
    // wait behind it; SQLite (WAL) handles the two threads.
    private val embedExec = Executors.newSingleThreadExecutor { r -> Thread(r, "aithra-embed") }
    private val embedder = Embedder()

    private lateinit var pickImage: ActivityResultLauncher<PickVisualMediaRequest>
    private lateinit var takePicture: ActivityResultLauncher<Uri>
    private lateinit var pickModel: ActivityResultLauncher<Array<String>>
    private lateinit var askPermission: ActivityResultLauncher<String>

    private var pendingImage: MethodChannel.Result? = null
    private var pendingModel: MethodChannel.Result? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var captureFile: File? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        // Created before super.onCreate, which attaches the Flutter engine
        // (configureFlutterEngine), so every callback that uses them, such
        // as onTrimMemory and onDestroy, finds them set.
        engineHost = EngineHost(applicationContext)
        db = ChatDb(applicationContext)
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
            io.execute {
                val outcome = runCatching { Media.importModel(this, uri) }
                runOnUiThread {
                    outcome.fold({ result.success(it) }, { result.error("import", it.message, null) })
                }
            }
        }
        askPermission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            pendingPermission?.success(granted)
            pendingPermission = null
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, "aithra/events").setStreamHandler(Events)
        MethodChannel(messenger, "aithra/native").setMethodCallHandler(::onCall)
    }

    /** Frees the model's memory when Android asks; Dart reloads it on next use. */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= TRIM_MEMORY_BACKGROUND) {
            engineHost.cancel()
            engineHost.submit({ engineHost.unload() }) {
                Events.send(mapOf("type" to "engine", "kind" to "released"))
            }
        }
    }

    override fun onDestroy() {
        speech.destroy()
        tts.shutdown()
        super.onDestroy()
    }

    private fun deliverImage(uri: Uri?) {
        val result = pendingImage ?: return
        pendingImage = null
        if (uri == null) {
            result.success(null)
            return
        }
        io.execute {
            val outcome = runCatching { Media.normalizeImage(this, uri) }
            captureFile?.delete()
            captureFile = null
            runOnUiThread {
                outcome.fold({ result.success(it) }, { result.error("image", it.message, null) })
            }
        }
    }

    private fun <T> onEngine(result: MethodChannel.Result, block: () -> T) =
        engineHost.submit(block) { reply(result, "engine", it) }

    private fun <T> onIo(result: MethodChannel.Result, block: () -> T) = runOn(io, "io", result, block)

    private fun <T> onDb(result: MethodChannel.Result, block: () -> T) = runOn(dbExec, "db", result, block)

    private fun <T> onEmbed(result: MethodChannel.Result, block: () -> T) = runOn(embedExec, "embed", result, block)

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

    @Suppress("UNCHECKED_CAST")
    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "engine.load" -> onEngine(result) { engineHost.load(call.arguments as Map<String, Any?>) }
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
                onEngine(result) {
                    engineHost.generate(request) { text ->
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
                engineHost.cancel()
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
            "db.truncate" -> onDb(result) { db.truncate(call.argument<String>("convId")!!, call.argument<Int>("fromSeq")!!) }
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

            "download.start" -> onIo(result) {
                Downloads.start(
                    this,
                    call.argument<String>("url")!!,
                    call.argument<String>("fileName")!!,
                    call.argument<String>("title")!!,
                )
            }
            "download.query" -> onIo(result) { Downloads.query(this) }
            "download.remove" -> onIo(result) { Downloads.remove(this, (call.argument<Number>("id")!!).toLong()) }
            "file.delete" -> onIo(result) { File(call.argument<String>("path")!!).delete() }
            "file.list" -> onIo(result) {
                modelsDir(this).listFiles()!!.filter { it.isFile }.map {
                    mapOf("path" to it.path, "name" to it.name, "size" to it.length())
                }
            }

            "import.model" -> {
                pendingModel = result
                pickModel.launch(arrayOf("*/*"))
            }
            "media.pickImage" -> {
                pendingImage = result
                pickImage.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly))
            }
            "media.capture" -> {
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
                    result.success(true)
                } else {
                    pendingPermission = result
                    askPermission.launch(Manifest.permission.RECORD_AUDIO)
                }
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
                startActivity(Intent(Settings.ACTION_VOICE_INPUT_SETTINGS))
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
