package dev.abdullah.aithra

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.res.Resources
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.speech.ModelDownloadListener
import android.speech.RecognitionListener
import android.speech.RecognitionService
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import org.xmlpull.v1.XmlPullParser
import java.util.Locale

/**
 * Android's built-in speech recognizer. Prefers the on-device recognizer
 * (API 31+); otherwise the default recognizer with EXTRA_PREFER_OFFLINE.
 *
 * One recognizer at a time serves listening, language checks and
 * downloads, and is released [RELEASE_AFTER_MS] after its last use.
 * Android keeps one connection per app to the recognition service, shared
 * by every recognizer, and:
 *  - destroying any recognizer unbinds it when none is mid-session, so a
 *    second recognizer would leave this one on a dead connection;
 *  - after the service's process dies, the connection stays marked
 *    disconnected, and every session opened on it answers
 *    ERROR_SERVER_DISCONNECTED, until a session on it closes and Android
 *    drops it.
 * Closing the recognizer when idle drops the connection with it, so each
 * use after a pause binds afresh and never inherits a dead connection.
 *
 * The recognizer stops after each utterance, so continuous dictation
 * restarts it after every final result (and after "no speech" timeouts)
 * until [stop] is called. All calls must be made on the main thread.
 */
class SpeechBridge(private val context: Context) {
    private val main = Handler(Looper.getMainLooper())
    private var recognizer: SpeechRecognizer? = null
    private var continuous = false
    private var active = false
    private var onDevice = false

    /**
     * Language checks awaiting the recognizer's answer. A broken connection
     * is reported only to the recognition listener, which fails these.
     */
    private val supportWaiters = mutableListOf<(ModelState?, Int?) -> Unit>()

    /** Like [supportWaiters], for a download request. */
    private var downloadPending = false

    /**
     * The language recognition and downloads use: a tag the on-device
     * recognizer reported (see [pickLanguage]) once [resolved], until then
     * the phone's own tag without its Unicode extensions (Android 14's
     * regional preferences add e.g. `-u-mu-celsius`, which no recognizer
     * lists).
     */
    private var language: String = Locale.getDefault().stripExtensions().toLanguageTag()
    private var resolved = false

    /**
     * The recognizer's last language report, for the diagnostics shown
     * with a language error; null until it has answered.
     */
    private var report: Map<String, List<String>>? = null

    /** A [listen] waits for [resolveLanguage] and runs when it answers. */
    private var awaitingLanguage = false

    private fun intent(): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
    }

    private val canCheckSupport
        get() = Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            SpeechRecognizer.isOnDeviceRecognitionAvailable(context)

    /**
     * Asks the on-device recognizer which languages it has and settles
     * [language] on the closest one. [done] gets the model state, or the
     * `SpeechRecognizer.ERROR_*` code when the recognizer cannot say.
     */
    private fun resolveLanguage(done: (state: ModelState?, error: Int?) -> Unit) {
        supportWaiters += done
        // Answers once: from this callback or from a broken connection.
        fun answer(state: ModelState?, error: Int?) {
            if (supportWaiters.remove(done)) {
                done(state, error)
                releaseWhenIdle()
            }
        }
        use().checkRecognitionSupport(
            intent(),
            context.mainExecutor,
            object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    val pending = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                        support.pendingOnDeviceLanguages
                    } else {
                        emptyList()
                    }
                    val (tag, state) = pickLanguage(
                        Locale.getDefault(),
                        support.installedOnDeviceLanguages,
                        pending,
                        support.supportedOnDeviceLanguages,
                    )
                    language = tag
                    resolved = true
                    report = mapOf(
                        "installed" to support.installedOnDeviceLanguages,
                        "pending" to pending,
                        "supported" to support.supportedOnDeviceLanguages,
                    )
                    answer(state, null)
                }

                override fun onError(error: Int) = answer(null, error)
            },
        )
    }

    private val release = Runnable {
        if (idle) {
            recognizer?.destroy()
            recognizer = null
        }
    }

    private val idle get() = !active && supportWaiters.isEmpty() && !downloadPending

    /** The recognizer, kept until [releaseWhenIdle] finds it unused. */
    private fun use(): SpeechRecognizer {
        main.removeCallbacks(release)
        return recognizer()
    }

    private fun releaseWhenIdle() {
        main.removeCallbacks(release)
        // The grace period lets back-to-back uses (a status check, then
        // listening) share one connection.
        if (idle) main.postDelayed(release, RELEASE_AFTER_MS)
    }

    fun status(callback: (Map<String, Any?>) -> Unit) {
        val base = mapOf(
            "available" to SpeechRecognizer.isRecognitionAvailable(context),
            "onDevice" to SpeechRecognizer.isOnDeviceRecognitionAvailable(context),
        )
        if (!canCheckSupport) {
            callback(base + mapOf("language" to language, "model" to "unknown"))
            return
        }
        resolveLanguage { state, _ ->
            Events.send(
                mapOf("type" to "speechStatus") + base +
                    mapOf("language" to language, "model" to (state?.wire ?: "unknown")) + diagnostics(),
            )
        }
        callback(base + mapOf("language" to language, "model" to "checking"))
    }

    private fun recognizer(): SpeechRecognizer = recognizer ?: run {
        onDevice = SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        (if (onDevice) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            SpeechRecognizer.createSpeechRecognizer(context)
        }).also {
            it.setRecognitionListener(listener)
            recognizer = it
        }
    }

    fun start(continuous: Boolean) {
        recognizer?.cancel()
        this.continuous = continuous
        active = true
        // The service is still winding down the cancelled session within
        // this call; starting in the same turn of the loop answers
        // ERROR_RECOGNIZER_BUSY.
        main.post { listen() }
    }

    private fun listen() {
        if (!active) return
        if (awaitingLanguage) return
        if (!resolved && canCheckSupport) {
            // Listening in a tag the recognizer does not list answers
            // ERROR_LANGUAGE_UNAVAILABLE even when its model is installed.
            awaitingLanguage = true
            resolveLanguage { _, _ ->
                awaitingLanguage = false
                // A recognizer that cannot report its languages is asked
                // in the phone's tag; its error then reaches the user.
                resolved = true
                listen()
            }
            return
        }
        use().startListening(intent())
    }

    /** Stops listening; the recognizer still delivers the final result. */
    fun stop() {
        continuous = false
        recognizer?.stopListening()
    }

    fun cancel() {
        active = false
        continuous = false
        recognizer?.cancel()
        releaseWhenIdle()
    }

    fun destroy() {
        cancel()
        main.removeCallbacks(release)
        recognizer?.destroy()
        recognizer = null
        supportWaiters.clear()
        downloadPending = false
    }

    /**
     * Asks the on-device recognizer to download the model for the language
     * it reported closest to the phone's (never a tag it did not list), and
     * reports the outcome as `speechDownload` events: `progress`, `success`,
     * `scheduled`, `requested` (the service took the request but reports
     * nothing back) or `error` with a `SpeechRecognizer.ERROR_*` code.
     * False when this phone has no on-device recognizer to ask.
     */
    fun downloadModel(): Boolean {
        if (!canCheckSupport) return false
        resolveLanguage { state, error ->
            when {
                error != null -> emitDownload("error", mapOf("code" to error))
                state == ModelState.INSTALLED -> emitDownload("success")
                state == ModelState.UNSUPPORTED ->
                    emitDownload("error", mapOf("code" to SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED))
                else -> triggerDownload()
            }
        }
        return true
    }

    private fun triggerDownload() {
        // The language check just answered on this recognizer, so it is
        // connected and sends the request at once; releasing it later does
        // not drop the request.
        val r = use()
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            r.triggerModelDownload(intent())
            emitDownload("requested")
            releaseWhenIdle()
            return
        }
        downloadPending = true
        r.triggerModelDownload(
            intent(),
            context.mainExecutor,
            object : ModelDownloadListener {
                override fun onProgress(completedPercent: Int) =
                    emitDownload("progress", mapOf("percent" to completedPercent))

                override fun onSuccess() {
                    downloadPending = false
                    resolved = false
                    emitDownload("success")
                    releaseWhenIdle()
                }

                override fun onScheduled() {
                    downloadPending = false
                    emitDownload("scheduled")
                    releaseWhenIdle()
                }

                override fun onError(error: Int) {
                    downloadPending = false
                    if (error == SpeechRecognizer.ERROR_CANNOT_LISTEN_TO_DOWNLOAD_EVENTS) {
                        // RecognitionService's default for the listener
                        // overload: it only answers this error and does not
                        // download. Services that download without
                        // reporting implement the plain overload.
                        r.triggerModelDownload(intent())
                        emitDownload("requested")
                    } else {
                        emitDownload("error", mapOf("code" to error))
                    }
                    releaseWhenIdle()
                }
            },
        )
    }

    /** The tag sent and what the recognizer last reported having. */
    private fun diagnostics(): Map<String, Any?> = mapOf("language" to language, "report" to report)

    private fun emitDownload(kind: String, extra: Map<String, Any?> = emptyMap()) {
        Events.send(mapOf("type" to "speechDownload", "kind" to kind) + diagnostics() + extra)
    }

    /**
     * The settings page of the on-device recognizer, where its languages
     * are added (Settings > System > Languages > Speech > On-device recognition),
     * found the way Settings itself finds it: the settings activity that
     * the recognizer's package declares in its `android.speech` meta-data.
     * Null when the phone has no such page.
     */
    fun onDeviceSettingsIntent(): Intent? {
        val id = Resources.getSystem()
            .getIdentifier("config_defaultOnDeviceSpeechRecognitionService", "string", "android")
        if (id == 0) return null
        val flat = Resources.getSystem().getString(id)
        val pkg = ComponentName.unflattenFromString(flat)?.packageName ?: return null
        val pm = context.packageManager
        val services = pm.queryIntentServices(
            Intent(RecognitionService.SERVICE_INTERFACE).setPackage(pkg),
            PackageManager.GET_META_DATA,
        )
        for (info in services) {
            val activity = info.serviceInfo.loadXmlMetaData(pm, RecognitionService.SERVICE_META_DATA)?.use { xml ->
                var event = xml.eventType
                while (event != XmlPullParser.END_DOCUMENT) {
                    if (event == XmlPullParser.START_TAG && xml.name == "recognition-service") {
                        return@use xml.getAttributeValue(ANDROID_NS, "settingsActivity")
                    }
                    event = xml.next()
                }
                null
            } ?: continue
            val component = ComponentName(pkg, if (activity.startsWith(".")) pkg + activity else activity)
            // Settings runs as the system and may open an activity other
            // apps cannot; only an exported one is reachable from here.
            val exported = runCatching { pm.getActivityInfo(component, 0).exported }.getOrDefault(false)
            if (exported) return Intent(Intent.ACTION_MAIN).setComponent(component)
        }
        return null
    }

    /**
     * The on-device recognizer's languages page when other apps may open
     * it, else the system Languages page, whose Speech > On-device
     * recognition leads there. Pixel's (Android System Intelligence) is
     * not exported. ACTION_VOICE_INPUT_SETTINGS is no substitute: on
     * Android 17 it opens the default assistant picker.
     */
    fun settingsIntent(): Intent =
        onDeviceSettingsIntent() ?: Intent(Settings.ACTION_LOCALE_SETTINGS)

    private fun emit(kind: String, extra: Map<String, Any?> = emptyMap()) {
        Events.send(
            mapOf(
                "type" to "speech",
                "kind" to kind,
                "t" to SystemClock.elapsedRealtime(),
                "onDevice" to onDevice,
            ) + extra,
        )
    }

    private fun restartOrFinish() {
        if (active && continuous) {
            // Starting again inside the recognizer's own callback answers
            // ERROR_RECOGNIZER_BUSY; the next loop turn is free.
            main.post { listen() }
        } else {
            active = false
            emit("idle")
            releaseWhenIdle()
        }
    }

    private val listener = object : RecognitionListener {
        override fun onReadyForSpeech(params: Bundle?) = emit("ready")
        override fun onBeginningOfSpeech() = emit("begin")
        override fun onRmsChanged(rmsdB: Float) = emit("level", mapOf("rms" to rmsdB.toDouble()))
        override fun onBufferReceived(buffer: ByteArray?) {}
        override fun onEndOfSpeech() = emit("end")

        override fun onError(error: Int) {
            val silent = error == SpeechRecognizer.ERROR_NO_MATCH ||
                error == SpeechRecognizer.ERROR_SPEECH_TIMEOUT
            if (silent) {
                emit("nomatch")
                restartOrFinish()
            } else {
                val listening = active
                active = false
                if (error in brokenConnection) {
                    // The next request builds a new recognizer, and a new
                    // connection. Requests the old one took are never
                    // answered now.
                    val broken = recognizer
                    recognizer = null
                    main.post { broken?.destroy() }
                    val waiters = supportWaiters.toList()
                    supportWaiters.clear()
                    waiters.forEach { it(null, error) }
                    if (downloadPending) {
                        downloadPending = false
                        emitDownload("error", mapOf("code" to error))
                    }
                }
                if (error == SpeechRecognizer.ERROR_LANGUAGE_NOT_SUPPORTED ||
                    error == SpeechRecognizer.ERROR_LANGUAGE_UNAVAILABLE
                ) {
                    // The installed languages may have changed since the
                    // last check; the next start asks again.
                    resolved = false
                }
                // A connection that breaks between sessions is not a
                // failed listen; the next one reconnects.
                if (listening) emit("error", mapOf("code" to error) + diagnostics())
                releaseWhenIdle()
            }
        }

        override fun onResults(results: Bundle?) {
            val text = results?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull() ?: ""
            emit("final", mapOf("text" to text))
            restartOrFinish()
        }

        override fun onPartialResults(partialResults: Bundle?) {
            val text = partialResults?.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION)?.firstOrNull()
            if (!text.isNullOrEmpty()) emit("partial", mapOf("text" to text))
        }

        override fun onEvent(eventType: Int, params: Bundle?) {}
    }
}

private const val ANDROID_NS = "http://schemas.android.com/apk/res/android"

/** Errors after which a recognizer's service connection is unusable. */
/** How long an unused recognizer is kept for the next request. */
private const val RELEASE_AFTER_MS = 2000L

private val brokenConnection = setOf(
    SpeechRecognizer.ERROR_SERVER,
    SpeechRecognizer.ERROR_CLIENT,
    SpeechRecognizer.ERROR_RECOGNIZER_BUSY,
    SpeechRecognizer.ERROR_SERVER_DISCONNECTED,
)
