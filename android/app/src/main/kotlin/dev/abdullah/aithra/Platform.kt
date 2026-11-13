package dev.abdullah.aithra

import android.app.ActivityManager
import android.content.Context
import android.graphics.Bitmap
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Build
import android.os.StatFs
import android.provider.OpenableColumns
import dev.abdullah.aithra.engine.CpuFeatures
import dev.abdullah.aithra.engine.LlamaNative
import java.io.ByteArrayOutputStream
import java.io.File

/**
 * Model files live in app-specific external storage: private, removed on
 * uninstall, and the only place DownloadManager (another process) can write
 * to for this app. It is null only while shared storage is unmounted.
 */
fun modelsDir(context: Context): File =
    File(checkNotNull(context.getExternalFilesDir(null)) { "Phone storage is not available right now" }, "models")
        .apply { mkdirs() }

object DeviceInfo {
    fun collect(context: Context): Map<String, Any?> {
        val am = context.getSystemService(ActivityManager::class.java)
        val mem = ActivityManager.MemoryInfo().also { am.getMemoryInfo(it) }
        val pkg = context.packageManager.getPackageInfo(context.packageName, 0)
        val features = File("/proc/cpuinfo").readLines()
            .firstOrNull { it.startsWith("Features") }
            ?.substringAfter(":")?.trim()
        return mapOf(
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "device" to Build.DEVICE,
            "androidRelease" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "socManufacturer" to Build.SOC_MANUFACTURER,
            "socModel" to Build.SOC_MODEL,
            "totalRamMb" to mem.totalMem / (1024 * 1024),
            "appVersion" to pkg.versionName,
            "appBuild" to pkg.longVersionCode,
            "cpuFeatures" to features,
            "llamaSystemInfo" to if (CpuFeatures.runsLlama) LlamaNative.nativeSystemInfo() else null,
            // The Tensor NPU dispatch library talks to this vendor library.
            "edgeTpuRuntime" to listOf("/vendor/lib64/libedgetpu_litert.so", "/system/lib64/libedgetpu_litert.so")
                .any { File(it).exists() },
        )
    }
}

object Storage {
    private const val DB = "aithra.db"

    private fun vaultFiles(context: Context) =
        context.filesDir.listFiles()!!.filter { it.name.endsWith(".vault") || it.name.endsWith(".vault.tmp") }

    /** Encrypted data from an earlier run: the chat database or a vault document. */
    fun hasData(context: Context): Boolean =
        context.getDatabasePath(DB).exists() || vaultFiles(context).isNotEmpty()

    /** Deletes all encrypted data. Only before the database is opened. */
    fun erase(context: Context) {
        context.deleteDatabase(DB)
        vaultFiles(context).forEach { it.delete() }
    }

    fun info(context: Context): Map<String, Any?> {
        val dir = modelsDir(context)
        val stat = StatFs(dir.path)
        return mapOf(
            "modelsDir" to dir.path,
            "freeBytes" to stat.availableBytes,
        )
    }
}

object Media {
    /** Decodes, downsizes to at most [maxSide] px on the long edge and re-encodes as JPEG. */
    fun normalizeImage(context: Context, uri: Uri, maxSide: Int = 1024): ByteArray {
        val source = ImageDecoder.createSource(context.contentResolver, uri)
        val bitmap = ImageDecoder.decodeBitmap(source) { decoder, info, _ ->
            val w = info.size.width
            val h = info.size.height
            val scale = minOf(1.0, maxSide.toDouble() / maxOf(w, h))
            decoder.setTargetSize((w * scale).toInt().coerceAtLeast(1), (h * scale).toInt().coerceAtLeast(1))
            decoder.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        }
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 88, out)
        return out.toByteArray()
    }

    /** A small JPEG for list thumbnails, made once when the image is stored. */
    fun thumbnail(jpeg: ByteArray, side: Int = 256): ByteArray {
        val full = android.graphics.BitmapFactory.decodeByteArray(jpeg, 0, jpeg.size)
        val scale = minOf(1.0, side.toDouble() / maxOf(full.width, full.height))
        val small = Bitmap.createScaledBitmap(
            full, (full.width * scale).toInt().coerceAtLeast(1), (full.height * scale).toInt().coerceAtLeast(1), true,
        )
        val out = ByteArrayOutputStream()
        small.compress(Bitmap.CompressFormat.JPEG, 80, out)
        return out.toByteArray()
    }

    fun displayName(context: Context, uri: Uri): String {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
            if (it.moveToFirst()) return it.getString(0)
        }
        return uri.lastPathSegment ?: "model"
    }

    const val PARTIAL_SUFFIX = ".importing"
    private val MODEL_EXTENSIONS = listOf(".litertlm", ".gguf")

    /**
     * Copies a picked model file into `models/imported/`, reporting progress
     * as `import` events. Imports live apart from catalog downloads so a
     * file named like a catalog model can neither replace nor hide one.
     */
    fun importModel(context: Context, uri: Uri): String {
        val name = displayName(context, uri).replace('/', '_')
        require(MODEL_EXTENSIONS.any { name.endsWith(it, ignoreCase = true) }) {
            "$name is not a model file. Aithra runs .litertlm and .gguf files."
        }
        val total = context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use {
            if (it.moveToFirst()) it.getLong(0) else -1L
        } ?: -1L
        val dir = File(modelsDir(context), IMPORTED_DIR).apply { mkdirs() }
        val target = File(dir, name)
        val partial = File(target.path + PARTIAL_SUFFIX)
        try {
            context.contentResolver.openInputStream(uri)!!.use { input ->
                partial.outputStream().use { output ->
                    val buf = ByteArray(1 shl 20)
                    var copied = 0L
                    var lastReport = 0L
                    while (true) {
                        val n = input.read(buf)
                        if (n < 0) break
                        output.write(buf, 0, n)
                        copied += n
                        if (copied - lastReport >= 32L shl 20) {
                            lastReport = copied
                            Events.send(mapOf("type" to "import", "copied" to copied, "total" to total))
                        }
                    }
                }
            }
            check(partial.renameTo(target)) { "Could not move the imported file into place" }
        } finally {
            partial.delete()
        }
        return target.path
    }

    const val IMPORTED_DIR = "imported"
}
