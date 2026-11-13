package dev.abdullah.aithra.engine

import java.util.concurrent.atomic.AtomicBoolean

object LlamaNative {
    init {
        check(CpuFeatures.runsLlama) { "This phone's CPU lacks the instructions llama.cpp is built for" }
        System.loadLibrary("aithra_llama")
        nativeInit()
    }

    fun interface TokenCallback {
        fun onToken(utf8: ByteArray): Boolean
    }

    external fun nativeInit()
    external fun nativeSystemInfo(): String
    external fun nativeLoad(path: String, threads: Int, nCtx: Int): Long
    external fun nativeFree(handle: Long)
    external fun nativeSetAbort(handle: Long, abort: Boolean)
    external fun nativeContextSize(handle: Long): Int
    external fun nativeCountTokens(handle: Long, text: String): Int
    external fun nativeGenerate(
        handle: Long,
        roles: Array<String>,
        contents: Array<String>,
        maxTokens: Int,
        ignoreEos: Boolean,
        temperature: Float,
        callback: TokenCallback,
    ): DoubleArray

    external fun nativeCountTurns(handle: Long, roles: Array<String>, contents: Array<String>): IntArray
    external fun nativePromptOverhead(handle: Long): Int

    external fun nativeEmbedLoad(path: String, threads: Int): Long
    external fun nativeEmbedFree(handle: Long)
    external fun nativeEmbed(handle: Long, text: String): FloatArray
}

/** llama.cpp on the CPU, for GGUF models. Text only. */
class LlamaEngine(path: String, threads: Int, nCtx: Int) : LlmEngine {
    private val handle = LlamaNative.nativeLoad(path, threads, nCtx)
    private val cancelled = AtomicBoolean(false)

    override val contextSize: Int = LlamaNative.nativeContextSize(handle)

    override fun generate(request: GenerateRequest, onText: (String) -> Boolean): GenerateStats {
        val roles = request.turns.map { it.role }.toTypedArray()
        val contents = request.turns.map { it.text }.toTypedArray()
        val r = LlamaNative.nativeGenerate(
            handle, roles, contents, request.maxTokens, request.ignoreEos, request.temperature,
        ) { bytes -> onText(String(bytes, Charsets.UTF_8)) && !cancelled.get() }
        return GenerateStats(
            promptTokens = r[0].toInt(),
            prefillMs = r[1],
            ttftMs = r[2],
            decodeTokens = r[3].toInt(),
            decodeMs = r[4],
            contextTokens = r[0].toInt() + r[3].toInt(),
            note = null,
            cancelled = r[5] != 0.0,
        )
    }

    override fun countTurns(turns: List<ChatTurn>): IntArray = LlamaNative.nativeCountTurns(
        handle,
        turns.map { it.role }.toTypedArray(),
        turns.map { it.text }.toTypedArray(),
    )

    override val promptOverhead: Int by lazy { LlamaNative.nativePromptOverhead(handle) }

    override fun cancel() {
        cancelled.set(true)
        LlamaNative.nativeSetAbort(handle, true)
    }

    override fun resetCancel() {
        cancelled.set(false)
        LlamaNative.nativeSetAbort(handle, false)
    }

    override fun close() = LlamaNative.nativeFree(handle)
}
