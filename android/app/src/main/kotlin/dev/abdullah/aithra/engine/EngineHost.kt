package dev.abdullah.aithra.engine

import android.content.Context
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicLong

/**
 * Owns the one loaded model. Every engine call runs on a single background
 * thread, so loads and generations are serialized and never touch the UI
 * thread; the engine stays loaded between calls until [unload] or another
 * [load].
 */
class EngineHost(private val context: Context) {
    private val worker = Executors.newSingleThreadExecutor { r -> Thread(r, "aithra-engine") }
    @Volatile private var engine: LlmEngine? = null

    fun <T> submit(block: () -> T, onResult: (Result<T>) -> Unit) {
        worker.execute { onResult(runCatching(block)) }
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

    fun generate(request: GenerateRequest, onText: (String) -> Boolean): Map<String, Any?> {
        val current = engine ?: throw IllegalStateException("No model is loaded")
        val sampler = RssSampler().also { it.start() }
        val stats = try {
            current.generate(request, onText)
        } finally {
            sampler.stop()
        }
        return stats.toMap() + ("peakRssMb" to sampler.peakMb)
    }

    /** Per-turn token counts and prompt overhead; both null without a tokenizer. */
    fun countTokens(turns: List<ChatTurn>): Map<String, Any?> {
        val current = engine ?: throw IllegalStateException("No model is loaded")
        return mapOf(
            "counts" to current.countTurns(turns)?.toList(),
            "overhead" to current.promptOverhead,
        )
    }

    /** Safe from any thread: interrupts the running generation. */
    fun cancel() {
        engine?.cancel()
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
