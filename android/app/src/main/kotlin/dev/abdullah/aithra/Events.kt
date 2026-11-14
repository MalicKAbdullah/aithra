package dev.abdullah.aithra

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.util.concurrent.CopyOnWriteArraySet

/**
 * One Flutter engine's native→Dart event stream. Every event is a map with
 * a `type`; sends from any thread are marshalled onto the main thread, as
 * EventChannel requires. Events that answer one engine's request (reply
 * tokens, a document's import progress) go to that engine's stream alone,
 * since each engine numbers its requests independently.
 */
class EventStream : EventChannel.StreamHandler {
    @Volatile private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        Events.streams += this
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        Events.streams -= this
    }

    fun send(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            sink?.success(event)
        } else {
            Events.main.post { sink?.success(event) }
        }
    }
}

/**
 * Process-wide events (`engine`, `import`, `speech`, `tts`, `inbox`), sent
 * to every Flutter engine that listens: the app and, while it is open, the
 * Ask sheet share the one loaded model and must both learn when it changes.
 */
object Events {
    internal val main = Handler(Looper.getMainLooper())
    internal val streams = CopyOnWriteArraySet<EventStream>()

    fun send(event: Map<String, Any?>) = streams.forEach { it.send(event) }
}
