package dev.abdullah.aithra.engine

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import java.util.concurrent.Executor

/**
 * Sentence embeddings from EmbeddingGemma through llama.cpp, for cross-chat
 * recall. The model loads on first use and is freed after a minute without
 * work, so it only holds memory while recall or indexing runs. Every call,
 * the idle release included, runs on [executor], so none of them waits on
 * another thread (least of all the main thread).
 */
class Embedder(private val executor: Executor) {
    private var handle = 0L
    private var path: String? = null
    private val main = Handler(Looper.getMainLooper())
    private var lastUse = 0L

    // The timer can fire while an embed runs; the check on the executor
    // keeps a model that was just used.
    private val freeIdle = Runnable {
        executor.execute { if (SystemClock.uptimeMillis() - lastUse >= IDLE_MS) release() }
    }

    /** Unit vectors of [DIMS] floats, one per text. Call on [executor]. */
    fun embed(modelPath: String, texts: List<String>): List<FloatArray> {
        main.removeCallbacks(freeIdle)
        if (path != modelPath) {
            ModelFormat.require(java.io.File(modelPath), "llamacpp")
            release()
            handle = LlamaNative.nativeEmbedLoad(modelPath, THREADS)
            path = modelPath
        }
        val out = texts.map { truncate(LlamaNative.nativeEmbed(handle, it)) }
        lastUse = SystemClock.uptimeMillis()
        main.postDelayed(freeIdle, IDLE_MS)
        return out
    }

    /** Frees the model now, after any embedding already queued. Any thread. */
    fun releaseNow() {
        main.removeCallbacks(freeIdle)
        executor.execute { release() }
    }

    private fun release() {
        if (handle != 0L) LlamaNative.nativeEmbedFree(handle)
        handle = 0L
        path = null
    }

    companion object {
        /**
         * EmbeddingGemma is trained with Matryoshka learning, so the first
         * 256 of its 768 dimensions, renormalised, keep most of the quality
         * at a third of the storage and scan time.
         */
        const val DIMS = 256
        private const val THREADS = 4
        private const val IDLE_MS = 60_000L

        // EmbeddingGemma's retrieval prompts.
        fun query(text: String) = "task: search result | query: $text"
        fun document(text: String) = "title: none | text: $text"

        private fun truncate(v: FloatArray): FloatArray {
            val out = v.copyOf(minOf(DIMS, v.size))
            var norm = 0.0
            for (x in out) norm += x * x
            val n = Math.sqrt(norm).toFloat()
            if (n > 0f) for (i in out.indices) out[i] /= n
            return out
        }
    }
}
