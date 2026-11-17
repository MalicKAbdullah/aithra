package dev.abdullah.aithra

import org.junit.Assert.assertEquals
import org.junit.Test

class RepliesTest {
    private class Host : Replies.Host {
        val log = mutableListOf<String>()
        override fun startService() { log += "start" }
        override fun stopService() { log += "stop" }
        override fun postReady(note: Replies.ReadyNote) { log += "ready ${note.chat}" }
        override fun clearReady() { log += "clear" }
        override fun visibilityChanged(visible: Boolean) { log += if (visible) "shown" else "hidden" }
    }

    private val host = Host()
    private val replies = Replies(host).apply { shown() }
    private val scopeA = 1L shl 32
    private val scopeB = 2L shl 32

    private fun note(chat: String) = Replies.ReadyNote("Picnic", chat, 7)

    @Test
    fun aReplyOnScreenShowsNothing() {
        host.log.clear()
        replies.begin(scopeA or 1)
        replies.end(scopeA or 1, note("c1"))
        // Nothing is started; ending with nothing running asks for no service.
        assertEquals(listOf("stop"), host.log)
    }

    @Test
    fun leavingMidReplyStartsTheServiceAndComingBackStopsIt() {
        replies.begin(scopeA or 1)
        host.log.clear()
        replies.hidden()
        assertEquals(listOf("start", "hidden"), host.log)
        host.log.clear()
        replies.shown()
        assertEquals(listOf("stop", "clear", "shown"), host.log)
    }

    @Test
    fun aReplyThatEndsWhileAwayIsAnnouncedAndTheServiceStops() {
        replies.begin(scopeA or 1)
        replies.hidden()
        host.log.clear()
        replies.end(scopeA or 1, note("c1"))
        assertEquals(listOf("ready c1", "stop"), host.log)
    }

    @Test
    fun aStoppedReplyEndsUnannounced() {
        replies.begin(scopeA or 1)
        replies.hidden()
        host.log.clear()
        replies.end(scopeA or 1, null)
        assertEquals(listOf("stop"), host.log)
    }

    @Test
    fun theServiceStaysWhileAnotherReplyRuns() {
        replies.begin(scopeA or 1)
        replies.begin(scopeA or 2)
        replies.hidden()
        host.log.clear()
        replies.end(scopeA or 1, note("c1"))
        assertEquals(listOf("ready c1"), host.log)
    }

    @Test
    fun anEngineThatGoesEndsOnlyItsOwnReplies() {
        replies.begin(scopeA or 1)
        replies.begin(scopeB or 1)
        replies.hidden()
        host.log.clear()
        replies.endScope(scopeA)
        assertEquals(emptyList<String>(), host.log)
        replies.endScope(scopeB)
        assertEquals(listOf("stop"), host.log)
    }

    @Test
    fun visibilityIsReportedOnlyWhenItChanges() {
        host.log.clear()
        replies.shown()
        assertEquals(emptyList<String>(), host.log)
    }
}
