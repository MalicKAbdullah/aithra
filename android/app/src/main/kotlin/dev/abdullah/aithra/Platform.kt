package dev.abdullah.aithra

import android.app.ActivityManager
import android.app.DownloadManager
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
    fun info(context: Context): Map<String, Any?> {
        val dir = modelsDir(context)
        val stat = StatFs(dir.path)
        return mapOf(
            "modelsDir" to dir.path,
            "freeBytes" to stat.availableBytes,
        )
    }
}

/** System DownloadManager: survives the app being backgrounded and resumes after network drops. */
object Downloads {
    fun start(context: Context, url: String, fileName: String, title: String): Long {
        val dm = context.getSystemService(DownloadManager::class.java)
        val target = File(modelsDir(context), fileName)
        if (target.exists()) target.delete()
        val request = DownloadManager.Request(Uri.parse(url))
            .setTitle(title)
            .setDescription(fileName)
            .setNotificationVisibility(DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            .setDestinationUri(Uri.fromFile(target))
            .setAllowedOverMetered(true)
        return dm.enqueue(request)
    }

    fun query(context: Context): List<Map<String, Any?>> {
        val dm = context.getSystemService(DownloadManager::class.java)
        val out = mutableListOf<Map<String, Any?>>()
        dm.query(DownloadManager.Query()).use { c ->
            while (c.moveToNext()) {
                fun long(col: String) = c.getLong(c.getColumnIndexOrThrow(col))
                fun str(col: String) = c.getString(c.getColumnIndexOrThrow(col))
                out += mapOf(
                    "id" to long(DownloadManager.COLUMN_ID),
                    "fileName" to str(DownloadManager.COLUMN_DESCRIPTION),
                    "status" to c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_STATUS)),
                    "reason" to c.getInt(c.getColumnIndexOrThrow(DownloadManager.COLUMN_REASON)),
                    "downloaded" to long(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR),
                    "total" to long(DownloadManager.COLUMN_TOTAL_SIZE_BYTES),
                )
            }
        }
        return out
    }

    /** Cancels (and deletes the partial file of) a download, or forgets a finished one. */
    fun remove(context: Context, id: Long) {
        context.getSystemService(DownloadManager::class.java).remove(id)
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

    /** Copies a picked model file into the models folder, reporting progress as `import` events. */
    fun importModel(context: Context, uri: Uri): String {
        val name = displayName(context, uri).replace('/', '_')
        val total = context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)?.use {
            if (it.moveToFirst()) it.getLong(0) else -1L
        } ?: -1L
        val target = File(modelsDir(context), name)
        val partial = File(target.path + ".importing")
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
        partial.renameTo(target)
        return target.path
    }
}
