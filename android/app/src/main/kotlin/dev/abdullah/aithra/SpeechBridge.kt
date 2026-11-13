package dev.abdullah.aithra

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.speech.RecognitionListener
import android.speech.RecognitionSupport
import android.speech.RecognitionSupportCallback
import android.speech.RecognizerIntent
import android.speech.SpeechRecognizer
import java.util.Locale
import java.util.concurrent.Executors

/**
 * Android's built-in speech recognizer. Prefers the on-device recognizer
 * (API 31+); otherwise the default recognizer with EXTRA_PREFER_OFFLINE.
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

    // triggerModelDownload hands the request to the recognizer's service;
    // destroying that recognizer drops the request, so it lives as long
    // as this bridge.
    private var downloader: SpeechRecognizer? = null

    /**
     * The language recognition runs in: the phone's own tag until the
     * on-device recognizer reports what it has, then the closest tag it
     * has (see [pickLanguage]). Status and recognition use the same value.
     */
    private var language: String = Locale.getDefault().toLanguageTag()

    private fun intent(): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, language)
    }

    fun status(callback: (Map<String, Any?>) -> Unit) {
        val base = mapOf(
            "available" to SpeechRecognizer.isRecognitionAvailable(context),
            "onDevice" to SpeechRecognizer.isOnDeviceRecognitionAvailable(context),
        )
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || !(base["onDevice"] as Boolean)) {
            callback(base + mapOf("language" to language, "languageInstalled" to null))
            return
        }
        val probe = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        probe.checkRecognitionSupport(
            intent(),
            Executors.newSingleThreadExecutor(),
            object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    main.post {
                        val (tag, installed) = pickLanguage(
                            Locale.getDefault(),
                            support.installedOnDeviceLanguages,
                            support.supportedOnDeviceLanguages,
                        )
                        language = tag
                        Events.send(
                            mapOf("type" to "speechStatus") + base +
                                mapOf("language" to tag, "languageInstalled" to installed),
                        )
                        probe.destroy()
                    }
                }

                override fun onError(error: Int) {
                    main.post {
                        Events.send(
                            mapOf("type" to "speechStatus") + base +
                                mapOf("language" to language, "languageInstalled" to null),
                        )
                        probe.destroy()
                    }
                }
            },
        )
        callback(base + mapOf("language" to language, "languageInstalled" to "checking"))
    }

    /**
     * Creates the recognizer ahead of the first tap so listening starts
     * without the service bind delay.
     */
    fun prewarm() {
        if (recognizer != null) return
        onDevice = SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        recognizer = (if (onDevice) {
            SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        } else {
            SpeechRecognizer.createSpeechRecognizer(context)
        }).apply { setRecognitionListener(listener) }
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
        prewarm()
        recognizer!!.startListening(intent())
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
    }

    fun destroy() {
        cancel()
        recognizer?.destroy()
        recognizer = null
        downloader?.destroy()
        downloader = null
    }

    /**
     * Asks the system to download the on-device model for [language].
     * False when this phone has no on-device recognizer to ask.
     */
    fun downloadModel(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU ||
            !SpeechRecognizer.isOnDeviceRecognitionAvailable(context)
        ) {
            return false
        }
        val r = downloader ?: SpeechRecognizer.createOnDeviceSpeechRecognizer(context).also { downloader = it }
        r.triggerModelDownload(intent())
        return true
    }

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
                active = false
                // After a client, server or busy error the recognizer's
                // service connection is unusable; the next start builds a
                // new one.
                val broken = recognizer
                recognizer = null
                main.post { broken?.destroy() }
                emit("error", mapOf("code" to error))
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

/**
 * The tag to recognize [wanted] in, and whether its on-device model is
 * installed: the exact tag when the recognizer has it, else another region
 * of the same language (en-US for en-PK), installed models first.
 */
fun pickLanguage(wanted: Locale, installed: List<String>, supported: List<String>): Pair<String, Boolean> {
    val tag = wanted.toLanguageTag()
    fun sameLanguage(t: String) = Locale.forLanguageTag(t).language == wanted.language
    installed.firstOrNull { it.equals(tag, ignoreCase = true) }?.let { return it to true }
    installed.firstOrNull(::sameLanguage)?.let { return it to true }
    supported.firstOrNull { it.equals(tag, ignoreCase = true) }?.let { return it to false }
    supported.firstOrNull(::sameLanguage)?.let { return it to false }
    return tag to false
}
