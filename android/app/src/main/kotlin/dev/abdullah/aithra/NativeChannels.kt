package dev.abdullah.aithra

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.LocaleList
import android.provider.Settings
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import dev.abdullah.aithra.engine.ChatTurn
import dev.abdullah.aithra.engine.CpuFeatures
import dev.abdullah.aithra.engine.Embedder
import dev.abdullah.aithra.engine.EngineCache
import dev.abdullah.aithra.engine.GenerateRequest
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.Locale
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicInteger

/**
 * The `aithra/native` method channel and `aithra/events` stream of one
 * Flutter engine, hosted by [activity]: the app (MainActivity) or the Ask
 * sheet (AskActivity). Both reach the same process-wide model, database and
 * embedder (AithraApplication). Create it while the activity is being
 * constructed or in onCreate, since it registers activity-result launchers;
 * [extra] answers the methods only its activity has.
 */
class NativeChannels(
    val activity: FlutterFragmentActivity,
    private val extra: (MethodCall, MethodChannel.Result) -> Boolean = { _, _ -> false },
) {
    private val app get() = activity.application as AithraApplication
    private val engineHost get() = app.engineHost
    private val db get() = app.db
    private val docs get() = app.db.documents
    private val embedder get() = app.embedder
    private val io get() = app.io

    /** This engine's events: reply tokens and import progress go here alone. */
    private val events = EventStream()

    /** Dart numbers requests from 0 in every engine; this keeps them apart natively. */
    private val scope = nextScope.getAndIncrement().toLong() shl 32
    private fun nativeId(requestId: Int) = scope or requestId.toLong()

    // The Ask sheet never speaks or listens; it does not pay for starting either.
    private val speechLazy = lazy { SpeechBridge(activity) }
    private val ttsLazy = lazy { TtsBridge(activity) }
    private val speech by speechLazy
    private val tts by ttsLazy

    // One request of each kind can be open at a time: each launcher has one
    // result slot.
    private var pendingImage: MethodChannel.Result? = null
    private var pendingModel: MethodChannel.Result? = null
    private var pendingDocument: MethodChannel.Result? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var captureFile: File? = null

    private val pickImage: ActivityResultLauncher<PickVisualMediaRequest> =
        activity.registerForActivityResult(ActivityResultContracts.PickVisualMedia()) { deliverImage(it) }
    private val takePicture: ActivityResultLauncher<Uri> =
        activity.registerForActivityResult(ActivityResultContracts.TakePicture()) { ok ->
            val file = captureFile
            deliverImage(if (ok && file != null) Uri.fromFile(file) else null)
        }
    private val pickModel: ActivityResultLauncher<Array<String>> =
        activity.registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            val result = pendingModel ?: return@registerForActivityResult
            pendingModel = null
            if (uri == null) result.success(null) else onIo(result) { Media.importModel(activity, uri) }
        }
    private val pickDocument: ActivityResultLauncher<Array<String>> =
        activity.registerForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            val result = pendingDocument ?: return@registerForActivityResult
            pendingDocument = null
            if (uri == null) result.success(null) else onIo(result) { importDocument(uri) }
        }

    // Downloads run the same either way; the answer only decides whether
    // their progress notification shows.
    private val askNotifications: ActivityResultLauncher<String> =
        activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) {}
    private val askPermission: ActivityResultLauncher<String> =
        activity.registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
            pendingPermission?.success(microphoneState(granted))
            pendingPermission = null
        }

    fun attach(flutterEngine: FlutterEngine) {
        val messenger = flutterEngine.dartExecutor.binaryMessenger
        EventChannel(messenger, "aithra/events").setStreamHandler(events)
        MethodChannel(messenger, "aithra/native").setMethodCallHandler(::onCall)
    }

    /** Sends [event] to this engine alone. */
    fun notify(event: Map<String, Any?>) = events.send(event)

    fun destroy() {
        if (speechLazy.isInitialized()) speech.destroy()
        if (ttsLazy.isInitialized()) tts.shutdown()
    }

    /** Reads a picked or shared file into a stored, unattached document. */
    fun importDocument(uri: Uri): Map<String, Any?> {
        val doc = Documents.extract(activity, uri) { done, total ->
            events.send(mapOf("type" to "document", "done" to done, "total" to total))
        }
        return docs.put(doc, System.currentTimeMillis())
    }

    /**
     * After a denial Android shows the rationale flag only while asking
     * again can still show the dialog; without it the denial is permanent
     * and only Settings can grant the microphone.
     */
    private fun microphoneState(granted: Boolean) = when {
        granted -> "granted"
        activity.shouldShowRequestPermissionRationale(Manifest.permission.RECORD_AUDIO) -> "denied"
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
                Media.normalizeImage(activity, uri)
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

    fun <T> onIo(result: MethodChannel.Result, block: () -> T) = runOn(io, "io", result, block)

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
    private fun <T> reply(result: MethodChannel.Result, code: String, outcome: Result<T>) = activity.runOnUiThread {
        outcome.fold(
            { result.success(if (it is Unit) null else it) },
            { result.error(code, it.message ?: it.javaClass.simpleName, null) },
        )
    }

    private fun startDownload(call: MethodCall, result: MethodChannel.Result) = onIo(result) {
        ModelDownloads.start(
            activity,
            call.argument<String>("url")!!,
            call.argument<String>("fileName")!!,
            call.argument<String>("title")!!,
            call.argument<Number>("size")!!.toLong(),
            call.argument<String>("sha256")!!,
        )
    }

    /** The user's languages first, then every other one the phone knows, by name. */
    private fun languages(): List<Map<String, String>> {
        val preferred = LocaleList.getDefault().let { list -> (0 until list.size()).map { list[it] } }
        val all = (preferred + Locale.getAvailableLocales().filter { it.country.isEmpty() && it.variant.isEmpty() })
        return all.map { it.language }.distinct()
            .map { Locale.forLanguageTag(it) }
            .filter { it.displayLanguage.isNotEmpty() && it.displayLanguage != it.language }
            .map { mapOf("tag" to it.toLanguageTag(), "name" to it.getDisplayLanguage(Locale.ENGLISH)) }
    }

    private fun progressNotification(call: MethodCall) {
        val manager = activity.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(DOCUMENT_CHANNEL, "Documents", NotificationManager.IMPORTANCE_LOW),
        )
        val open = PendingIntent.getActivity(
            activity, 0,
            Intent(activity, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_IMMUTABLE,
        )
        val done = call.argument<Int>("done")
        val total = call.argument<Int>("total")
        val builder = android.app.Notification.Builder(activity, DOCUMENT_CHANNEL)
            .setSmallIcon(R.mipmap.ic_launcher)
            .setContentTitle(call.argument<String>("title"))
            .setContentText(call.argument<String>("text"))
            .setContentIntent(open)
            .setOngoing(done != null)
            .setAutoCancel(done == null)
        if (done != null && total != null) builder.setProgress(total, done, false)
        manager.notify(call.argument<String>("tag"), DOCUMENT_NOTIFICATION, builder.build())
    }

    @Suppress("UNCHECKED_CAST")
    private fun onCall(call: MethodCall, result: MethodChannel.Result) {
        if (extra(call, result)) return
        when (call.method) {
            "engine.load" -> onEngineHeld(result) { engineHost.load(call.arguments as Map<String, Any?>) }
            "engine.generate" -> {
                val requestId = call.argument<Int>("requestId")!!
                val id = nativeId(requestId)
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
                engineHost.enqueue(id, call.argument<Boolean>("background") == true)
                onEngineHeld(result) {
                    engineHost.generate(id, request) { text ->
                        events.send(mapOf("type" to "token", "requestId" to requestId, "text" to text))
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
                engineHost.cancel(nativeId(call.argument<Int>("requestId")!!))
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
                    call.argument<List<String>>("keepDocs")!!.toSet(),
                )
            }
            "db.putImage" -> onDb(result) {
                val jpeg = call.argument<ByteArray>("jpeg")!!
                db.putImage(call.argument<String>("id")!!, jpeg, Media.thumbnail(jpeg))
            }
            "db.image" -> onDb(result) { db.image(call.argument<String>("id")!!, call.argument<Boolean>("thumb")!!) }
            "db.search" -> onDb(result) { db.search(call.argument<String>("query")!!, call.argument<Int>("limit")!!) }
            "db.searchText" -> onDb(result) { db.searchText(call.argument<String>("query")!!, call.argument<Int>("limit")!!) }
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
            "embed.texts" -> onEmbed(result) {
                val query = call.argument<Boolean>("query")!!
                embedder.embed(
                    call.argument<String>("modelPath")!!,
                    call.argument<List<String>>("texts")!!.map { if (query) Embedder.query(it) else Embedder.document(it) },
                )
            }
            "db.indexVectors" -> onEmbed(result) {
                db.indexVectors(embedder, call.argument<String>("modelPath")!!, call.argument<Int>("limit")!!)
            }
            "db.selfTest" -> onDb(result) { db.selfTest(call.argument<Int>("messages")!!) }

            "doc.pick" -> claim(pendingDocument, result) {
                pendingDocument = result
                // Code and data files often have no registered MIME type;
                // extraction decides by content and extension.
                pickDocument.launch(arrayOf("*/*"))
            }
            "doc.importUri" -> onIo(result) { importDocument(Uri.parse(call.argument<String>("uri")!!)) }
            // A file a share copied in (Inbox.read); the copy goes once read.
            "doc.importShared" -> onIo(result) {
                val file = File(call.argument<String>("path")!!)
                try {
                    docs.put(
                        Documents.extract(activity, call.argument<String>("name")!!, call.argument<String>("mime"), { _, _ -> }) {
                            file.inputStream()
                        },
                        System.currentTimeMillis(),
                    )
                } finally {
                    file.delete()
                }
            }
            "inbox.take" -> result.success(Inbox.take())
            "doc.importText" -> onIo(result) {
                val text = call.argument<String>("text")!!
                docs.put(
                    ExtractedDocument(call.argument<String>("name")!!, "text/plain", listOf(PageContent(0, text, null)), false),
                    System.currentTimeMillis(),
                )
            }
            "doc.get" -> onDb(result) { docs.document(call.argument<String>("id")!!) }
            "doc.ofConversation" -> onDb(result) { docs.ofConversation(call.argument<String>("convId")!!) }
            "doc.attach" -> onDb(result) {
                docs.attach(call.argument<String>("convId")!!, call.argument<Number>("msgId")!!.toLong(), call.argument<List<String>>("ids")!!)
            }
            "doc.delete" -> onDb(result) { docs.delete(call.argument<String>("id")!!) }
            "doc.pages" -> onDb(result) { docs.pages(call.argument<String>("id")!!) }
            "doc.unreadPages" -> onDb(result) { docs.unreadPages(call.argument<String>("id")!!) }
            "doc.setPageText" -> onDb(result) {
                docs.setPageText(call.argument<String>("id")!!, call.argument<Int>("page")!!, call.argument<String>("text")!!)
            }
            "doc.setSummary" -> onDb(result) {
                docs.setSummary(call.argument<String>("id")!!, call.argument<String>("parts"), call.argument<String>("summary"))
            }
            "doc.pendingSummaries" -> onDb(result) { docs.pendingSummaries() }
            "doc.passagesInOrder" -> onDb(result) {
                docs.passagesInOrder(call.argument<List<String>>("ids")!!, call.argument<Int>("limit")!!)
            }
            "doc.passage" -> onDb(result) { docs.passage(call.argument<String>("docId")!!, call.argument<Int>("ord")!!) }
            "doc.index" -> onEmbed(result) {
                docs.index(embedder, call.argument<String>("modelPath")!!, null, call.argument<Int>("limit")!!)
            }
            "doc.search" -> onEmbed(result) {
                docs.search(
                    embedder,
                    call.argument<String>("modelPath")!!,
                    call.argument<List<String>>("ids")!!,
                    call.argument<String>("query")!!,
                    call.argument<Int>("limit")!!,
                )
            }
            "doc.putCitations" -> onDb(result) {
                docs.putCitations(call.argument<Number>("msgId")!!.toLong(), call.argument<List<Map<String, Any?>>>("cites")!!)
            }
            "doc.citations" -> onDb(result) { docs.citations(call.argument<String>("convId")!!) }

            "notify.progress" -> {
                progressNotification(call)
                result.success(null)
            }
            "notify.cancel" -> {
                activity.getSystemService(NotificationManager::class.java)
                    .cancel(call.argument<String>("tag"), DOCUMENT_NOTIFICATION)
                result.success(null)
            }
            "locale.languages" -> onIo(result) { languages() }

            "device.info" -> onIo(result) { DeviceInfo.collect(activity) }
            "device.runsLlama" -> result.success(CpuFeatures.runsLlama)

            "crash.read" -> result.success(CrashLog.read(activity))
            "crash.record" -> onIo(result) {
                CrashLog.record(activity, call.argument<String>("title")!!, call.argument<String>("detail")!!)
            }
            "crash.clear" -> onIo(result) { CrashLog.clear(activity) }

            // Internal storage: always present, so startup never depends on
            // shared storage being mounted.
            "storage.dataDir" -> result.success(activity.filesDir.path)
            "storage.info" -> onIo(result) { Storage.info(activity) }
            "storage.hasData" -> onIo(result) { Storage.hasData(activity) }
            "storage.erase" -> onIo(result) { Storage.erase(activity) }

            "download.start" -> {
                if (activity.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                    askNotifications.launch(Manifest.permission.POST_NOTIFICATIONS)
                }
                startDownload(call, result)
            }
            "download.query" -> onIo(result) { ModelDownloads.query(activity) }
            "download.remove" -> onIo(result) { ModelDownloads.remove(activity, (call.argument<Number>("id")!!).toLong()) }
            "file.delete" -> onIo(result) {
                val path = call.argument<String>("path")!!
                EngineCache.forget(activity, path)
                File(path).delete()
            }
            // Complete files only, named relative to the models folder
            // ("imported/x.gguf" for imports).
            "file.list" -> onIo(result) {
                val root = modelsDir(activity)
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
                val file = File(activity.cacheDir, "capture/photo.jpg").apply { parentFile!!.mkdirs() }
                captureFile = file
                takePicture.launch(FileProvider.getUriForFile(activity, "${activity.packageName}.files", file))
            }
            "share.text" -> {
                val send = Intent(Intent.ACTION_SEND).apply {
                    type = "text/plain"
                    putExtra(Intent.EXTRA_TEXT, call.argument<String>("text"))
                }
                activity.startActivity(Intent.createChooser(send, null))
                result.success(null)
            }

            "permission.microphone" -> {
                if (activity.checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
                    result.success("granted")
                } else {
                    claim(pendingPermission, result) {
                        pendingPermission = result
                        askPermission.launch(Manifest.permission.RECORD_AUDIO)
                    }
                }
            }
            "permission.openSettings" -> {
                activity.startActivity(
                    Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.fromParts("package", activity.packageName, null)),
                )
                result.success(null)
            }
            "speech.status" -> speech.status { result.success(it) }
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
                activity.startActivity(speech.settingsIntent())
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

    companion object {
        private val nextScope = AtomicInteger(1)
        private const val DOCUMENT_CHANNEL = "documents"
        private const val DOCUMENT_NOTIFICATION = 2
    }
}
