package dev.abdullah.aithra.engine

import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Test

class ConversationCacheTest {
    private class Fake : AutoCloseable {
        var closed = false
        override fun close() {
            closed = true
        }
    }

    private fun sys() = ChatTurn("system", "You are Aithra.", emptyList())
    private fun user(t: String, images: List<ByteArray> = emptyList(), context: String = "") =
        ChatTurn("user", t, images, context)
    private fun model(t: String) = ChatTurn("model", t, emptyList())

    /** The cache after a first exchange: system, "Hi", reply "Hello!". */
    private fun afterFirstReply(state: Fake = Fake()): Pair<ConversationCache<Fake>, Fake> {
        val cache = ConversationCache<Fake>()
        cache.keep(state, listOf(sys(), user("Hi"), model("Hello!")), 0.7f)
        return cache to state
    }

    @Test
    fun theNextMessageReusesTheState() {
        val (cache, state) = afterFirstReply()
        // The stored reply is trimmed; the streamed one may not have been.
        val history = listOf(sys(), user("Hi"), model("Hello!\n"))
        assertSame(state, cache.take(history, 0.7f))
        assertFalse(state.closed)
    }

    @Test
    fun aTakenStateIsNoLongerHeld() {
        val (cache, state) = afterFirstReply()
        val history = listOf(sys(), user("Hi"), model("Hello!"))
        assertSame(state, cache.take(history, 0.7f))
        // A run that fails never returns it, so nothing stale is reused.
        assertNull(cache.take(history, 0.7f))
    }

    @Test
    fun earlierContextDoesNotBreakTheMatch() {
        val cache = ConversationCache<Fake>()
        val state = Fake()
        cache.keep(state, listOf(sys(), user("Tides?", context = "Notes: we spoke of tides"), model("High at 9.")), 0.7f)
        assertSame(state, cache.take(listOf(sys(), user("Tides?"), model("High at 9.")), 0.7f))
    }

    @Test
    fun regenerateDropsTheState() {
        val (cache, state) = afterFirstReply()
        // Regenerate sends the history up to the question again.
        assertNull(cache.take(listOf(sys()), 0.7f))
        assertTrue(state.closed)
    }

    @Test
    fun anEditedMessageDropsTheState() {
        val (cache, state) = afterFirstReply()
        assertNull(cache.take(listOf(sys(), user("Hey"), model("Hello!")), 0.7f))
        assertTrue(state.closed)
    }

    @Test
    fun aChangedSystemTurnDropsTheState() {
        val (cache, state) = afterFirstReply()
        val summarized = ChatTurn("system", "You are Aithra.\nSummary: greetings.", emptyList())
        assertNull(cache.take(listOf(summarized, user("Hi"), model("Hello!")), 0.7f))
        assertTrue(state.closed)
    }

    @Test
    fun anotherChatDropsTheState() {
        val (cache, state) = afterFirstReply()
        assertNull(cache.take(listOf(sys(), user("Recipe?"), model("Sure.")), 0.7f))
        assertTrue(state.closed)
    }

    @Test
    fun otherSamplingDropsTheState() {
        val (cache, state) = afterFirstReply()
        assertNull(cache.take(listOf(sys(), user("Hi"), model("Hello!")), 0.2f))
        assertTrue(state.closed)
    }

    @Test
    fun imagesMatchByContent() {
        val cache = ConversationCache<Fake>()
        val state = Fake()
        cache.keep(state, listOf(sys(), user("What is this?", listOf(byteArrayOf(1, 2, 3))), model("A cat.")), 0.7f)
        // Images are read from the store again for every turn.
        assertSame(state, cache.take(listOf(sys(), user("What is this?", listOf(byteArrayOf(1, 2, 3))), model("A cat.")), 0.7f))

        cache.keep(state, listOf(sys(), user("What is this?", listOf(byteArrayOf(1, 2, 3))), model("A cat.")), 0.7f)
        // Older photos stop being sent once newer ones arrive.
        assertNull(cache.take(listOf(sys(), user("What is this?"), model("A cat.")), 0.7f))
        assertTrue(state.closed)
    }

    @Test
    fun keepingAnotherStateClosesTheHeldOne() {
        val (cache, first) = afterFirstReply()
        cache.keep(Fake(), listOf(sys(), user("Other")), 0.7f)
        assertTrue(first.closed)
    }

    @Test
    fun clearClosesTheHeldState() {
        val (cache, state) = afterFirstReply()
        cache.clear()
        assertTrue(state.closed)
        assertNull(cache.take(listOf(sys(), user("Hi"), model("Hello!")), 0.7f))
    }
}
