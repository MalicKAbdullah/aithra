package dev.abdullah.aithra.engine

/**
 * One message of a conversation as the engines see it. [context] is
 * material retrieved for this turn only (recalled snippets), read in front
 * of [text]. It is not part of the turn's identity: a kept conversation
 * whose earlier turns carried context still matches a history that no
 * longer repeats it (see [ConversationCache]).
 */
data class ChatTurn(
    val role: String,
    val text: String,
    val images: List<ByteArray>,
    val context: String = "",
) {
    /** What the model reads for this turn. */
    val prompt: String get() = if (context.isEmpty()) text else "$context\n\n$text"
}

data class GenerateRequest(
    val turns: List<ChatTurn>,
    val maxTokens: Int,
    /** 0 means greedy decoding (used by calibration so answers are reproducible). */
    val temperature: Float,
    /** Keep decoding past end-of-sequence so speed runs always produce [maxTokens]. */
    val ignoreEos: Boolean,
    /**
     * A chat reply: the engine keeps the conversation's processed state
     * afterwards, so a next request that extends these turns prefills only
     * its new turn. Other requests (titles, memory, calibration) run on a
     * state of their own and leave the kept one alone.
     */
    val keepContext: Boolean = false,
)

/**
 * Counts and timings of one generation. A null count means the engine did not
 * report it; Dart shows that as "not measured" rather than guessing.
 */
data class GenerateStats(
    /** Prompt tokens prefilled by this run; reused ones are [reusedTokens]. */
    val promptTokens: Int?,
    val prefillMs: Double?,
    val ttftMs: Double?,
    val decodeTokens: Int?,
    val decodeMs: Double?,
    val contextTokens: Int?,
    val note: String?,
    /** Stopped by [LlmEngine.cancel] before the reply was complete. */
    val cancelled: Boolean,
    /** Prompt tokens already processed by the kept state and not prefilled again. */
    val reusedTokens: Int? = null,
) {
    companion object {
        /** A request cancelled before the engine started on it. */
        val cancelledBeforeStart = GenerateStats(null, null, null, null, null, null, null, cancelled = true)
    }

    fun toMap(): Map<String, Any?> = mapOf(
        "promptTokens" to promptTokens,
        "prefillMs" to prefillMs,
        "ttftMs" to ttftMs,
        "decodeTokens" to decodeTokens,
        "decodeMs" to decodeMs,
        "contextTokens" to contextTokens,
        "note" to note,
        "cancelled" to cancelled,
        "reusedTokens" to reusedTokens,
    )
}

interface LlmEngine : AutoCloseable {
    /** Size of the KV cache in tokens: prompt plus reply must fit in it. */
    val contextSize: Int

    /**
     * Runs one generation on the calling thread, streaming text to [onText].
     * [onText] returns false to stop early.
     */
    fun generate(request: GenerateRequest, onText: (String) -> Boolean): GenerateStats

    /**
     * Stops the running [generate] from another thread, or the next one if
     * it has not started yet, until [resetCancel].
     */
    fun cancel()

    /** Called on the engine thread before each request. */
    fun resetCancel()

    /**
     * Exact tokens each turn adds to a prompt, template markup included, or
     * null when the runtime exposes no tokenizer; callers then track the
     * context from the counts each [generate] reports.
     */
    fun countTurns(turns: List<ChatTurn>): IntArray?

    /** Tokens a prompt costs beyond its turns; null when [countTurns] is. */
    val promptOverhead: Int?
}
