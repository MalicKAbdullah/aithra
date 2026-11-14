package dev.abdullah.aithra

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.speech.tts.Voice
import android.view.textclassifier.TextClassificationManager
import android.view.textclassifier.TextLanguage
import java.util.Locale

/** One sentence to speak and how to speak it. */
data class Utterance(
    val text: String,
    val id: String,
    /** BCP 47 tag; null speaks in the phone's language. */
    val language: String?,
    /** A voice name from [TtsBridge.voices]; used when it speaks [language]. */
    val voice: String?,
    val rate: Float,
)

/**
 * Android's built-in TextToSpeech. Utterances queue in order, each in its
 * own language and voice; events report each one's end.
 */
class TtsBridge(context: Context) {
    private enum class State { STARTING, READY, FAILED }

    private val appContext = context.applicationContext
    private var state = State.STARTING
    private val pending = mutableListOf<Utterance>()
    private val voiceWaiters = mutableListOf<(List<Map<String, Any?>>) -> Unit>()

    /** The language and voice last set on the engine; changing them reloads the engine's voice. */
    private var applied: Pair<String?, String?>? = null

    private val tts: TextToSpeech = TextToSpeech(appContext) { status ->
        state = if (status == TextToSpeech.SUCCESS) State.READY else State.FAILED
        if (state == State.READY) {
            pending.forEach(::speakNow)
        } else {
            pending.forEach { fail(it.id) }
        }
        pending.clear()
        val list = voices()
        voiceWaiters.forEach { it(list) }
        voiceWaiters.clear()
    }

    init {
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String) =
                Events.send(mapOf("type" to "tts", "kind" to "start", "id" to utteranceId))

            override fun onRangeStart(utteranceId: String, start: Int, end: Int, frame: Int) =
                Events.send(mapOf("type" to "tts", "kind" to "word", "id" to utteranceId))

            override fun onDone(utteranceId: String) =
                Events.send(mapOf("type" to "tts", "kind" to "done", "id" to utteranceId))

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String) =
                Events.send(mapOf("type" to "tts", "kind" to "error", "id" to utteranceId))

            override fun onStop(utteranceId: String, interrupted: Boolean) =
                Events.send(mapOf("type" to "tts", "kind" to "stopped", "id" to utteranceId))
        })
    }

    fun speak(u: Utterance) {
        when (state) {
            State.READY -> speakNow(u)
            State.STARTING -> pending += u
            State.FAILED -> fail(u.id)
        }
    }

    /**
     * Voices that speak without a network connection and are installed:
     * Aithra never sends text off the phone. Answers once the engine is up.
     */
    fun voices(callback: (List<Map<String, Any?>>) -> Unit) {
        when (state) {
            State.STARTING -> voiceWaiters += callback
            else -> callback(voices())
        }
    }

    private fun voices(): List<Map<String, Any?>> {
        if (state != State.READY) return emptyList()
        return (tts.voices ?: emptySet())
            .filter { it.isOffline() }
            .sortedWith(compareBy({ it.locale.toLanguageTag() }, { -it.quality }, { it.name }))
            .map {
                mapOf(
                    "name" to it.name,
                    "language" to it.locale.toLanguageTag(),
                    // In the phone's language, for the settings list.
                    "label" to it.locale.displayName,
                    "quality" to it.quality,
                )
            }
    }

    private fun Voice.isOffline() =
        !isNetworkConnectionRequired && TextToSpeech.Engine.KEY_FEATURE_NOT_INSTALLED !in features

    private fun fail(id: String) = Events.send(mapOf("type" to "tts", "kind" to "error", "id" to id))

    private fun speakNow(u: Utterance) {
        apply(u.language, u.voice)
        tts.setSpeechRate(u.rate)
        // The language, voice and rate are read when the utterance is
        // queued, so each queued sentence keeps its own.
        tts.speak(u.text, TextToSpeech.QUEUE_ADD, null, u.id)
    }

    private fun apply(language: String?, voiceName: String?) {
        if (applied == language to voiceName) return
        applied = language to voiceName
        val locale = language?.let(Locale::forLanguageTag) ?: Locale.getDefault()
        val chosen = voiceName?.let { name -> tts.voices?.firstOrNull { it.name == name } }
        if (chosen != null && chosen.isOffline() && chosen.locale.language == locale.language) {
            tts.voice = chosen
        } else {
            tts.language = locale
        }
    }

    fun stop() {
        pending.clear()
        tts.stop()
    }

    fun shutdown() = tts.shutdown()

    companion object {
        /**
         * The language [text] is written in, from Android's on-device
         * TextClassifier, or null when it is less sure than not (very short
         * replies): the phone's own language is then the better guess.
         * Blocking; call off the main thread.
         */
        fun detectLanguage(context: Context, text: String): String? {
            val classifier = context.getSystemService(TextClassificationManager::class.java).textClassifier
            val result = classifier.detectLanguage(TextLanguage.Request.Builder(text).build())
            if (result.localeHypothesisCount == 0) return null
            val top = result.getLocale(0)
            return if (result.getConfidenceScore(top) >= 0.5f) top.toLanguageTag() else null
        }
    }
}
