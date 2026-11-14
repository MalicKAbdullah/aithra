package dev.abdullah.aithra.engine

/**
 * Holds at most one conversation state [C] together with the exact turns it
 * has processed, so a chat reply that extends those turns sends only its new
 * message instead of prefilling the whole history again.
 *
 * Ownership moves with [take]: while a generation runs nothing is held, so a
 * failed or cancelled run (whose state is unknown) simply never comes back
 * through [keep] and is closed by the caller. Anything that changes the
 * history (an edit, a regenerate, a summary, a different chat, an older
 * message dropped to make room) makes the prefix differ, and the held state
 * is closed rather than reused.
 */
class ConversationCache<C : AutoCloseable> {
    private var held: C? = null
    private var processed: List<ChatTurn> = emptyList()
    private var sampling: Any? = null

    /**
     * The held state when it has processed exactly [prefix] under
     * [sampling] (sampler settings are fixed when a conversation opens);
     * otherwise null, and a held state that does not match is closed.
     */
    fun take(prefix: List<ChatTurn>, sampling: Any): C? {
        val state = held ?: return null
        held = null
        if (sampling == this.sampling && sameTurns(processed, prefix)) return state
        state.close()
        return null
    }

    /** Holds [state], which has processed [turns], closing any other. */
    fun keep(state: C, turns: List<ChatTurn>, sampling: Any) {
        held?.close()
        held = state
        processed = turns
        this.sampling = sampling
    }

    fun clear() {
        held?.close()
        held = null
        processed = emptyList()
    }

    companion object {
        fun sameTurns(a: List<ChatTurn>, b: List<ChatTurn>): Boolean =
            a.size == b.size && a.indices.all { sameTurn(a[it], b[it]) }

        /**
         * Replies are stored trimmed, so a model turn matches the text the
         * engine streamed up to surrounding whitespace. Context is ignored:
         * it belonged to the turn it was retrieved for (see [ChatTurn]).
         */
        fun sameTurn(a: ChatTurn, b: ChatTurn): Boolean =
            a.role == b.role &&
                (if (a.role == "model") a.text.trim() == b.text.trim() else a.text == b.text) &&
                a.images.size == b.images.size &&
                a.images.indices.all { a.images[it].contentEquals(b.images[it]) }
    }
}
