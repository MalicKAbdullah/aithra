package dev.abdullah.aithra

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.ClipboardManager
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import androidx.core.content.FileProvider
import java.io.File

/** What leaves Aithra on the user's request: copies, shared and saved images, opened links. */
object RichOutput {
    /**
     * Puts [text] on the clipboard with [html] alongside, so apps that take
     * formatting (Docs, Gmail) paste headings, lists and tables, and the
     * rest paste the plain text.
     */
    fun copy(context: Context, text: String, html: String?) {
        val clip = if (html == null) {
            ClipData.newPlainText("Aithra", text)
        } else {
            ClipData.newHtmlText("Aithra", text, html)
        }
        context.getSystemService(ClipboardManager::class.java).setPrimaryClip(clip)
    }

    /** Writes [png] where the FileProvider serves it from and returns its content URI. */
    fun stageImage(context: Context, png: ByteArray, name: String): Uri {
        val dir = File(context.cacheDir, "shared").apply { mkdirs() }
        // One shared image at a time: the previous one is no longer needed.
        dir.listFiles()?.forEach { it.delete() }
        val file = File(dir, "${safeName(name)}.png")
        file.writeBytes(png)
        return FileProvider.getUriForFile(context, "${context.packageName}.files", file)
    }

    fun shareImage(activity: Activity, uri: Uri) {
        val send = Intent(Intent.ACTION_SEND).apply {
            type = "image/png"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(Intent.createChooser(send, null))
    }

    /** Saves [png] to Pictures/Aithra through MediaStore, which needs no storage permission. */
    fun saveImage(context: Context, png: ByteArray, name: String) {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Images.Media.DISPLAY_NAME, "${safeName(name)}.png")
            put(MediaStore.Images.Media.MIME_TYPE, "image/png")
            put(MediaStore.Images.Media.RELATIVE_PATH, "${Environment.DIRECTORY_PICTURES}/Aithra")
            put(MediaStore.Images.Media.IS_PENDING, 1)
        }
        val uri = checkNotNull(resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)) {
            "Android did not let Aithra save to Pictures"
        }
        try {
            checkNotNull(resolver.openOutputStream(uri)) { "Could not open the new picture" }.use { it.write(png) }
            values.clear()
            values.put(MediaStore.Images.Media.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }
    }

    /** Opens [url] in the app that handles it; false when no app on the phone does. */
    fun openUrl(activity: Activity, url: String): Boolean = try {
        activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(url)).addCategory(Intent.CATEGORY_BROWSABLE))
        true
    } catch (_: ActivityNotFoundException) {
        false
    }

    private fun safeName(name: String) = name.replace(Regex("[^A-Za-z0-9 _-]"), "").trim().ifEmpty { "Aithra" }.take(60)
}
