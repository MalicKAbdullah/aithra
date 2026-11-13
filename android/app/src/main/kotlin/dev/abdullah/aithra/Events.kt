package dev.abdullah.aithra

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel

/**
 * The single native→Dart event stream. Every event is a map with a `type`
 * (`token`, `import`, `speech`, `tts`); sends from any thread are marshalled
 * onto the main thread, as EventChannel requires.
 */
object Events : EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    @Volatile private var sink: EventChannel.EventSink? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun send(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            sink?.success(event)
        } else {
            main.post { sink?.success(event) }
        }
    }
}
