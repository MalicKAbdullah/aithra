package dev.abdullah.aithra

/**
 * What the user should see of the replies they wait for. While any Aithra
 * activity is on screen, Android keeps the process running and nothing is
 * shown. When the last one leaves with a reply in progress, the foreground
 * service keeps the process running and says so; it ends when the user
 * comes back or the last reply ends. A reply that ends while the screen it
 * belongs to (the app, or that Ask sheet) is not showing leaves a "Reply
 * ready" notification, which that screen clears when it shows.
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
        fun visibilityChanged(visible: Boolean)

        /** Whether any engine has a reply in progress changed. */
        fun replyingChanged(replying: Boolean)
    }

    /** A finished reply to announce: [chat] opens it, or null for the Ask sheet in task [askTask]. */
    data class ReadyNote(val title: String, val chat: String?, val askTask: Int)

    private val running = HashSet<Long>()

    /** No activity has started yet when the process starts. */
    var visible = false
        private set

    val replying get() = running.isNotEmpty()

    fun begin(id: Long) {
        running += id
        if (running.size == 1) host.replyingChanged(true)
        if (!visible) host.startService()
    }

    /**
     * Ends reply [id]; [ready] when it delivered something, announced
     * unless the screen it belongs to is showing ([ownerShown]).
     */
    fun end(id: Long, ready: ReadyNote?, ownerShown: Boolean) {
        if (ready != null && !ownerShown) host.postReady(ready)
        remove { it == id }
    }

    /** Ends every reply of [scope] without announcing any: its engine is gone. */
    fun endScope(scope: Long) = remove { (it and SCOPE_MASK) == scope }

    private fun remove(which: (Long) -> Boolean) {
        if (!running.removeAll(which)) return
        if (running.isEmpty()) {
            host.stopService()
            host.replyingChanged(false)
        }
    }

    fun shown() {
        if (visible) return
        visible = true
        host.stopService()
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
