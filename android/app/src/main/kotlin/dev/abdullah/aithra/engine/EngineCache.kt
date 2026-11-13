package dev.abdullah.aithra.engine

import android.content.Context
import java.io.File

/**
 * Where LiteRT-LM keeps what it builds on a model's first load: compiled
 * GPU programs and serialized GPU weights (`<model>_mldrift_*.bin`) and
 * the XNNPack weight cache (`<model>.xnnpack_cache`). Reusing them turns the
 * GPU backend's long first load into a short one, so they live in
 * no-backup files storage, which Android never clears to free space as it
 * does the cache directory; they are removed with their model instead.
 */
object EngineCache {
    fun dir(context: Context): File = File(context.noBackupFilesDir, "litertlm").apply { mkdirs() }

    /** Total bytes of the cache files, by name. */
    fun snapshot(context: Context): Map<String, Long> =
        dir(context).listFiles()?.associate { it.name to it.length() } ?: emptyMap()

    /** Bytes the load between [before] and [after] wrote into the cache. */
    fun written(before: Map<String, Long>, after: Map<String, Long>): Long =
        after.entries.sumOf { (name, size) -> if (before[name] == size) 0L else size }

    /** Drops the cache files built for the model at [modelPath]. */
    fun forget(context: Context, modelPath: String) {
        val stem = File(modelPath).nameWithoutExtension
        dir(context).listFiles()?.filter { it.name.startsWith(stem) }?.forEach { it.delete() }
    }

    /**
     * Earlier builds kept the cache in the cache directory; moving it keeps
     * the work already done there.
     */
    fun migrate(context: Context) {
        val old = File(context.cacheDir, "litertlm")
        if (!old.exists()) return
        val target = File(context.noBackupFilesDir, "litertlm")
        if (target.exists() || !old.renameTo(target)) old.deleteRecursively()
    }
}
