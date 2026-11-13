package dev.abdullah.aithra

import android.content.Context
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import java.util.Locale

/** Android's built-in TextToSpeech. Utterances queue in order; events report each one's end. */
class TtsBridge(context: Context) {
    private enum class State { STARTING, READY, FAILED }

    private var state = State.STARTING
    private val pending = mutableListOf<Pair<String, String>>()
    private val tts: TextToSpeech = TextToSpeech(context.applicationContext) { status ->
        state = if (status == TextToSpeech.SUCCESS) State.READY else State.FAILED
        if (state == State.READY) {
            tts.language = Locale.getDefault()
            pending.forEach { (text, id) -> speakNow(text, id) }
        } else {
            pending.forEach { (_, id) -> fail(id) }
        }
        pending.clear()
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

    fun speak(text: String, id: String) {
        when (state) {
            State.READY -> speakNow(text, id)
            State.STARTING -> pending += text to id
            State.FAILED -> fail(id)
        }
    }

    private fun fail(id: String) = Events.send(mapOf("type" to "tts", "kind" to "error", "id" to id))

    private fun speakNow(text: String, id: String) {
        tts.speak(text, TextToSpeech.QUEUE_ADD, null, id)
    }

    fun stop() {
        pending.clear()
        tts.stop()
    }

    fun shutdown() = tts.shutdown()
}
