package dev.abdullah.aithra.engine

/** One message of a conversation as the engines see it. */
data class ChatTurn(val role: String, val text: String, val images: List<ByteArray>)

data class GenerateRequest(
    val turns: List<ChatTurn>,
    val maxTokens: Int,
    /** 0 means greedy decoding (used by calibration so answers are reproducible). */
    val temperature: Float,
    /** Keep decoding past end-of-sequence so speed runs always produce [maxTokens]. */
    val ignoreEos: Boolean,
)

/**
 * Counts and timings of one generation. A null count means the engine did not
 * report it; Dart shows that as "not measured" rather than guessing.
 */
data class GenerateStats(
    val promptTokens: Int?,
    val prefillMs: Double?,
    val ttftMs: Double?,
    val decodeTokens: Int?,
    val decodeMs: Double?,
    val contextTokens: Int?,
    val note: String?,
) {
    fun toMap(): Map<String, Any?> = mapOf(
        "promptTokens" to promptTokens,
        "prefillMs" to prefillMs,
        "ttftMs" to ttftMs,
        "decodeTokens" to decodeTokens,
        "decodeMs" to decodeMs,
        "contextTokens" to contextTokens,
        "note" to note,
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

    /** Interrupts a running [generate] from another thread. */
    fun cancel()

    /**
     * Exact tokens each turn adds to a prompt, template markup included, or
     * null when the runtime exposes no tokenizer; callers then track the
     * context from the counts each [generate] reports.
     */
    fun countTurns(turns: List<ChatTurn>): IntArray?

    /** Tokens a prompt costs beyond its turns; null when [countTurns] is. */
    val promptOverhead: Int?
}
