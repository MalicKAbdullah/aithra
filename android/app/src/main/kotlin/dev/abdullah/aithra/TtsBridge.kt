package dev.abdullah.aithra

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale

/** Android's built-in TextToSpeech. Utterances queue in order; events report each one's end. */
class TtsBridge(context: Context) {
    private var ready = false
    private val pending = mutableListOf<Pair<String, String>>()
    private val tts: TextToSpeech = TextToSpeech(context.applicationContext) { status ->
        ready = status == TextToSpeech.SUCCESS
        if (ready) {
            tts.language = Locale.getDefault()
            pending.forEach { (text, id) -> speakNow(text, id) }
        } else {
            pending.forEach { (_, id) -> Events.send(mapOf("type" to "tts", "kind" to "error", "id" to id)) }
        }
        pending.clear()
    }

    init {
        tts.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
            override fun onStart(utteranceId: String) =
                Events.send(mapOf("type" to "tts", "kind" to "start", "id" to utteranceId))

            override fun onDone(utteranceId: String) =
                Events.send(mapOf("type" to "tts", "kind" to "done", "id" to utteranceId))

            @Deprecated("Deprecated in Java")
            override fun onError(utteranceId: String) =
                Events.send(mapOf("type" to "tts", "kind" to "error", "id" to utteranceId))

            override fun onStop(utteranceId: String, interrupted: Boolean) =
                Events.send(mapOf("type" to "tts", "kind" to "stopped", "id" to utteranceId))
        })
    }

    fun speak(text: String, id: String) {
        if (ready) speakNow(text, id) else pending += text to id
    }

    private fun speakNow(text: String, id: String) {
        tts.speak(text, TextToSpeech.QUEUE_ADD, null, id)
    }

    fun stop() {
        pending.clear()
        tts.stop()
    }

    fun shutdown() = tts.shutdown()
}
