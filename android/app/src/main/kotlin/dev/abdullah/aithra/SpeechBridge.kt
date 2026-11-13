package dev.abdullah.aithra

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
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
    private var recognizer: SpeechRecognizer? = null
    private var continuous = false
    private var active = false
    private var onDevice = false

    private fun intent(): Intent = Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH).apply {
        putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM)
        putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true)
        putExtra(RecognizerIntent.EXTRA_PREFER_OFFLINE, true)
        putExtra(RecognizerIntent.EXTRA_LANGUAGE, Locale.getDefault().toLanguageTag())
    }

    fun status(callback: (Map<String, Any?>) -> Unit) {
        val base = mapOf(
            "available" to SpeechRecognizer.isRecognitionAvailable(context),
            "onDevice" to SpeechRecognizer.isOnDeviceRecognitionAvailable(context),
            "language" to Locale.getDefault().toLanguageTag(),
        )
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU || !(base["onDevice"] as Boolean)) {
            callback(base + ("languageInstalled" to null))
            return
        }
        val probe = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        probe.checkRecognitionSupport(
            intent(),
            Executors.newSingleThreadExecutor(),
            object : RecognitionSupportCallback {
                override fun onSupportResult(support: RecognitionSupport) {
                    val tag = Locale.getDefault().toLanguageTag()
                    val lang = Locale.getDefault().language
                    val installed = support.installedOnDeviceLanguages.any { it == tag || it.startsWith(lang) }
                    Events.send(mapOf("type" to "speechStatus") + base + ("languageInstalled" to installed))
                    android.os.Handler(context.mainLooper).post { probe.destroy() }
                }

                override fun onError(error: Int) {
                    Events.send(mapOf("type" to "speechStatus") + base + ("languageInstalled" to null))
                    android.os.Handler(context.mainLooper).post { probe.destroy() }
                }
            },
        )
        callback(base + ("languageInstalled" to "checking"))
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
        prewarm()
        recognizer?.cancel()
        this.continuous = continuous
        active = true
        recognizer?.startListening(intent())
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
    }

    /** Asks the system to download the on-device model for the current language. */
    fun downloadModel(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return false
        val r = SpeechRecognizer.createOnDeviceSpeechRecognizer(context)
        r.triggerModelDownload(intent())
        r.destroy()
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
            recognizer?.startListening(intent())
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
