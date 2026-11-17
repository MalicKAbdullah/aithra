package dev.abdullah.aithra

/**
 * What the user should see of the replies they wait for, by whether an
 * Aithra activity is on screen. While one is, nothing: the reply is in
 * front of them. When the last one leaves with a reply in progress, the
 * foreground service keeps the process running and says so; it ends when
 * the user comes back or the last reply ends. A reply that ends while the
 * user is away leaves a "Reply ready" notification, cleared when they
 * come back.
 *
 * Main thread only. Reply ids are scoped per Flutter engine (see
 * NativeChannels), so the app's and the Ask sheet's never collide.
 */
class Replies(private val host: Host) {
    interface Host {
        /** Starts the foreground service; it must still be allowed to. */
        fun startService()
        fun stopService()
        fun postReady(note: ReadyNote)
        fun clearReady()
        fun visibilityChanged(visible: Boolean)
    }

    /** A finished reply to announce: [chat] opens it, or null for the Ask sheet in task [askTask]. */
    data class ReadyNote(val title: String, val chat: String?, val askTask: Int)

    private val running = HashSet<Long>()

    /** No activity has started yet when the process starts. */
    var visible = false
        private set

    fun begin(id: Long) {
        running += id
        if (!visible) host.startService()
    }

    /** Ends reply [id]; [ready] when it delivered something the user has not seen. */
    fun end(id: Long, ready: ReadyNote?) {
        running -= id
        if (!visible && ready != null) host.postReady(ready)
        if (running.isEmpty()) host.stopService()
    }

    /** Ends every reply of [scope] without announcing any: its engine is gone. */
    fun endScope(scope: Long) {
        if (!running.removeAll { (it and SCOPE_MASK) == scope }) return
        if (running.isEmpty()) host.stopService()
    }

    fun shown() {
        if (visible) return
        visible = true
        host.stopService()
        host.clearReady()
        host.visibilityChanged(true)
    }

    fun hidden() {
        if (!visible) return
        visible = false
        if (running.isNotEmpty()) host.startService()
        host.visibilityChanged(false)
    }

    companion object {
        const val SCOPE_MASK = -1L shl 32
    }
}
