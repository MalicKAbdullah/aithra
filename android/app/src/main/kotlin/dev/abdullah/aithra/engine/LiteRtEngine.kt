@file:OptIn(ExperimentalApi::class)

package dev.abdullah.aithra.engine

import com.google.ai.edge.litertlm.ActivationDataType
import com.google.ai.edge.litertlm.Backend
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Conversation
import com.google.ai.edge.litertlm.ConversationConfig
import com.google.ai.edge.litertlm.Engine
import com.google.ai.edge.litertlm.EngineConfig
import com.google.ai.edge.litertlm.ExperimentalApi
import com.google.ai.edge.litertlm.ExperimentalFlags
import com.google.ai.edge.litertlm.Message
import com.google.ai.edge.litertlm.MessageCallback
import com.google.ai.edge.litertlm.SamplerConfig
import java.util.concurrent.CountDownLatch

/**
 * LiteRT-LM for `.litertlm` bundles (Gemma 4 and the Tensor NPU builds).
 *
 * [backend] is one of `cpu`, `gpu`, `gpu_fp32` (GPU with float32 activations,
 * which some Mali drivers need for correct output), `npu` (LiteRT dispatch
 * library bundled from litert-npu-runtime-google-tensor) or `tensor`
 * (LiteRT-LM's Google Tensor backend).
 */
class LiteRtEngine(
    path: String,
    backend: String,
    vision: Boolean,
    maxTokens: Int?,
    cacheDir: String,
    nativeLibraryDir: String,
) : LlmEngine {
    private val engine: Engine
    @Volatile private var active: Conversation? = null
    private val cancelled = java.util.concurrent.atomic.AtomicBoolean(false)

    override val contextSize: Int

    init {
        // Per-conversation prefill/decode counters; must be set before the
        // engine is created.
        ExperimentalFlags.enableBenchmark = true
        val main = when (backend) {
            "cpu" -> Backend.CPU()
            "gpu", "gpu_fp32" -> Backend.GPU()
            "npu" -> Backend.NPU(nativeLibraryDir)
            "tensor" -> Backend.GOOGLE_TENSOR()
            else -> throw IllegalArgumentException("Unknown LiteRT-LM backend $backend")
        }
        val visionBackend = if (!vision) null else if (main is Backend.CPU) Backend.CPU() else Backend.GPU()
        val config = EngineConfig(
            modelPath = path,
            backend = main,
            visionBackend = visionBackend,
            audioBackend = null,
            maxNumTokens = maxTokens,
            cacheDir = cacheDir,
            activationDataType = if (backend == "gpu_fp32") ActivationDataType.FLOAT32 else null,
        )
        engine = Engine(config)
        engine.initialize()
        contextSize = maxTokens ?: 4096
    }

    override fun generate(request: GenerateRequest, onText: (String) -> Boolean): GenerateStats {
        val history = request.turns.dropLast(1).map(::toMessage)
        val last = toMessage(request.turns.last())
        val sampler = if (request.temperature <= 0f) {
            SamplerConfig(topK = 1, topP = 1.0, temperature = 1.0, seed = 0)
        } else {
            SamplerConfig(topK = 40, topP = 0.95, temperature = request.temperature.toDouble(), seed = 0)
        }
        val conversation = engine.createConversation(
            ConversationConfig(initialMessages = history, samplerConfig = sampler),
        )
        active = conversation
        // A cancel that arrived before [active] was set only raised the flag.
        if (cancelled.get()) {
            active = null
            conversation.close()
            return GenerateStats.cancelledBeforeStart
        }
        val start = System.nanoTime()
        var firstTokenNs = 0L
        var failure: Throwable? = null
        val done = CountDownLatch(1)
        try {
            conversation.sendMessageAsync(
                last,
                object : MessageCallback {
                    override fun onMessage(message: Message) {
                        if (firstTokenNs == 0L) firstTokenNs = System.nanoTime()
                        val text = message.contents.contents
                            .filterIsInstance<Content.Text>()
                            .joinToString("") { it.text }
                        if (text.isNotEmpty() && !onText(text)) conversation.cancelProcess()
                    }

                    override fun onDone() = done.countDown()

                    override fun onError(throwable: Throwable) {
                        failure = throwable
                        done.countDown()
                    }
                },
                maxOutputToken = request.maxTokens,
            )
            done.await()
            failure?.let { if (it !is java.util.concurrent.CancellationException) throw it }

            val ttftMs = if (firstTokenNs == 0L) null else (firstTokenNs - start) / 1e6
            return try {
                val info = conversation.getBenchmarkInfo()
                GenerateStats(
                    promptTokens = info.lastPrefillTokenCount,
                    prefillMs = msFor(info.lastPrefillTokenCount, info.lastPrefillTokensPerSecond),
                    ttftMs = ttftMs,
                    decodeTokens = info.lastDecodeTokenCount,
                    decodeMs = msFor(info.lastDecodeTokenCount, info.lastDecodeTokensPerSecond),
                    contextTokens = conversation.getTokenCount(),
                    note = null,
                    cancelled = cancelled.get(),
                )
            } catch (e: Exception) {
                GenerateStats(null, null, ttftMs, null, null, null, "benchmark info: ${e.message}", cancelled.get())
            }
        } finally {
            active = null
            conversation.close()
        }
    }

    override fun cancel() {
        cancelled.set(true)
        active?.cancelProcess()
    }

    override fun resetCancel() = cancelled.set(false)

    // LiteRT-LM 0.19.1 has no tokenizer API; usage comes from each
    // conversation's reported token count instead.
    override fun countTurns(turns: List<ChatTurn>): IntArray? = null

    override val promptOverhead: Int? = null

    override fun close() = engine.close()

    private fun msFor(tokens: Int, perSecond: Double): Double? =
        if (tokens <= 0 || perSecond <= 0.0) null else tokens / perSecond * 1000.0

    private fun toMessage(turn: ChatTurn): Message {
        val parts = turn.images.map { Content.ImageBytes(it) } + Content.Text(turn.text)
        val contents = Contents.of(parts)
        return when (turn.role) {
            "user" -> Message.user(contents)
            "system" -> Message.system(contents)
            else -> Message.model(contents)
        }
    }
}
