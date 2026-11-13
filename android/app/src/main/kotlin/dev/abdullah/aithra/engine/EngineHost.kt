package dev.abdullah.aithra.engine

import android.content.Context
import dev.abdullah.aithra.Events
import dev.abdullah.aithra.InferenceService
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * Owns the one loaded model. Every engine call runs on a single background
 * thread, so loads and generations are serialized and never touch the UI
 * thread; the engine stays loaded between calls until [unload] or another
 * [load].
 *
 * Generations are cancelled by request id, so a Stop that arrives while
 * the request still waits in the queue, or during its prefill, is not lost.
 */
class EngineHost(private val context: Context) {
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "aithra-engine") }
    @Volatile private var engine: LlmEngine? = null

    private val lock = Any()
    private val queued = HashSet<Int>()
    private val cancelled = HashSet<Int>()
    private var running: Int? = null

    fun <T> submit(block: () -> T, onResult: (Result<T>) -> Unit) {
        worker.execute { onResult(runCatching(block)) }
    }

    /** Like [submit], with the process kept in the foreground while it runs. */
    fun <T> submitHeld(block: () -> T, onResult: (Result<T>) -> Unit) {
        InferenceService.acquire(context)
        worker.execute {
            val result = runCatching(block)
            InferenceService.release(context)
            onResult(result)
        }
    }

    /** Marks [requestId] as waiting for the engine; call when it is submitted. */
    fun enqueue(requestId: Int) = synchronized(lock) { queued += requestId }

    /** Cancels [requestId] whether it is waiting or running. Any thread. */
    fun cancel(requestId: Int) = synchronized(lock) {
        if (requestId !in queued) return@synchronized
        cancelled += requestId
        if (running == requestId) engine?.cancel()
    }

    /**
     * Stops whatever runs and frees the model, for Android's memory
     * pressure; the reply that was cut short reports `cancelled`.
     */
    fun release() {
        synchronized(lock) {
            running?.let { cancelled += it }
            engine?.cancel()
        }
        submit({ unload() }) {
            Events.send(mapOf("type" to "engine", "kind" to "released"))
        }
    }

    /** Returns load time and peak RSS while loading. */
    fun load(args: Map<String, Any?>): Map<String, Any?> {
        engine?.close()
        engine = null
        val path = args["path"] as String
        val runtime = args["runtime"] as String
        val sampler = RssSampler().also { it.start() }
        val start = System.nanoTime()
        val loaded = try {
            when (runtime) {
                "litertlm" -> LiteRtEngine(
                    path = path,
                    backend = args["backend"] as String,
                    vision = args["vision"] as Boolean,
                    maxTokens = args["maxTokens"] as Int?,
                    cacheDir = File(context.cacheDir, "litertlm").apply { mkdirs() }.path,
                    nativeLibraryDir = context.applicationInfo.nativeLibraryDir,
                )
                "llamacpp" -> LlamaEngine(path, args["threads"] as Int, args["maxTokens"] as Int)
                else -> throw IllegalArgumentException("Unknown runtime $runtime")
            }
        } finally {
            sampler.stop()
        }
        engine = loaded
        return mapOf(
            "loadMs" to (System.nanoTime() - start) / 1e6,
            "peakRssMb" to sampler.peakMb,
            "contextSize" to loaded.contextSize,
        )
    }

    fun generate(requestId: Int, request: GenerateRequest, onText: (String) -> Boolean): Map<String, Any?> {
        try {
            val current = engine ?: throw IllegalStateException("No model is loaded")
            synchronized(lock) {
                running = requestId
                current.resetCancel()
                if (requestId in cancelled) return GenerateStats.cancelledBeforeStart.toMap()
            }
            val sampler = RssSampler().also { it.start() }
            val stats = try {
                current.generate(request, onText)
            } finally {
                sampler.stop()
            }
            return stats.toMap() + ("peakRssMb" to sampler.peakMb)
        } finally {
            synchronized(lock) {
                running = null
                queued -= requestId
                cancelled -= requestId
            }
        }
    }

    /** Per-turn token counts and prompt overhead; both null without a tokenizer. */
    fun countTokens(turns: List<ChatTurn>): Map<String, Any?> {
        val current = engine ?: throw IllegalStateException("No model is loaded")
        return mapOf(
            "counts" to current.countTurns(turns)?.toList(),
            "overhead" to current.promptOverhead,
        )
    }

    fun unload() {
        engine?.close()
        engine = null
    }
}

/** Samples this process's resident set size until stopped and keeps the peak. */
class RssSampler {
    private val peakKb = AtomicLong(0)
    @Volatile private var running = false
    private var thread: Thread? = null

    val peakMb: Double get() = peakKb.get() / 1024.0

    fun start() {
        running = true
        thread = Thread({
            while (running) {
                peakKb.accumulateAndGet(currentRssKb()) { a, b -> maxOf(a, b) }
                Thread.sleep(50)
            }
        }, "aithra-rss").apply { isDaemon = true; start() }
    }

    fun stop() {
        running = false
        thread?.join()
        peakKb.accumulateAndGet(currentRssKb()) { a, b -> maxOf(a, b) }
    }

    companion object {
        fun currentRssKb(): Long =
            File("/proc/self/status").readLines()
                .first { it.startsWith("VmRSS:") }
                .split(Regex("\\s+"))[1].toLong()
    }
}
