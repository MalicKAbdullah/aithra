package dev.abdullah.aithra

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.graphics.Matrix
import android.graphics.pdf.PdfRenderer
import android.graphics.pdf.PdfRendererPreV
import android.graphics.pdf.RenderParams
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.os.ext.SdkExtensions
import android.util.Xml
import org.xmlpull.v1.XmlPullParser
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CharacterCodingException
import java.nio.charset.Charset
import java.nio.charset.CodingErrorAction
import java.util.zip.ZipInputStream

/**
 * One page of an imported document. [text] is null for a PDF page without
 * a text layer (a scan); its [image] is then read by the vision model. A
 * document without pages (text, Word) is a single page 0.
 */
class PageContent(val page: Int, val text: String?, val image: ByteArray?)

class ExtractedDocument(val name: String, val mime: String, val pages: List<PageContent>, val paged: Boolean)

/** Reads a picked or shared file into text, page by page. */
object Documents {
    const val PDF = "application/pdf"
    const val DOCX = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

    /** Text kept from one document; also the size limit for a plain text file. */
    const val MAX_CHARS = 2_000_000
    const val MAX_TEXT_BYTES = 2 * 1024 * 1024

    /**
     * Scanned pages rendered for the vision model. Each costs a model run
     * when the document is first used, so a long scan stops here.
     */
    const val MAX_VISION_PAGES = 30

    fun extract(context: Context, uri: Uri, onProgress: (done: Int, total: Int) -> Unit): ExtractedDocument {
        val name = Media.displayName(context, uri)
        val type = context.contentResolver.getType(uri)
        val ext = name.substringAfterLast('.', "").lowercase()
        return when {
            type == PDF || ext == "pdf" -> pdf(context, uri, name, onProgress)
            type == DOCX || ext == "docx" -> context.contentResolver.openInputStream(uri)!!.use {
                ExtractedDocument(name, DOCX, listOf(PageContent(0, capped(name, DocxText.extract(it, Xml.newPullParser())), null)), false)
            }
            else -> {
                val bytes = context.contentResolver.openInputStream(uri)!!.use { readAtMost(it, MAX_TEXT_BYTES + 1) }
                require(bytes.size <= MAX_TEXT_BYTES) { "$name is larger than 2 MB. Aithra reads text files up to 2 MB." }
                val text = requireNotNull(TextDecoding.decode(bytes)) {
                    "$name isn't a text, PDF or Word (.docx) file."
                }
                ExtractedDocument(name, type ?: "text/plain", listOf(PageContent(0, capped(name, text), null)), false)
            }
        }
    }

    private fun capped(name: String, text: String): String {
        require(text.length <= MAX_CHARS) { tooLong(name) }
        return text
    }

    private fun tooLong(name: String) = "$name has more text than Aithra can keep (2 million characters)."

    private fun readAtMost(input: InputStream, limit: Int): ByteArray {
        val out = ByteArrayOutputStream()
        val buf = ByteArray(64 * 1024)
        while (out.size() < limit) {
            val n = input.read(buf, 0, minOf(buf.size, limit - out.size()))
            if (n < 0) break
            out.write(buf, 0, n)
        }
        return out.toByteArray()
    }

    /**
     * PdfRenderer needs a seekable descriptor, which a content provider may
     * not give (a pipe from a cloud provider), so the file is copied to the
     * cache first and deleted once read.
     */
    private fun pdf(context: Context, uri: Uri, name: String, onProgress: (Int, Int) -> Unit): ExtractedDocument {
        val copy = File(context.cacheDir, "import/${System.nanoTime()}.pdf").apply { parentFile!!.mkdirs() }
        try {
            context.contentResolver.openInputStream(uri)!!.use { input -> copy.outputStream().use { input.copyTo(it) } }
            ParcelFileDescriptor.open(copy, ParcelFileDescriptor.MODE_READ_ONLY).use { fd ->
                val pdf = PdfPages.open(fd)
                try {
                    val pages = ArrayList<PageContent>(pdf.count)
                    var chars = 0
                    var rendered = 0
                    for (i in 0 until pdf.count) {
                        onProgress(i, pdf.count)
                        val text = pdf.text(i)?.trim()?.takeIf { it.isNotEmpty() }
                        if (text != null) {
                            chars += text.length
                            require(chars <= MAX_CHARS) { tooLong(name) }
                            pages += PageContent(i + 1, text, null)
                        } else {
                            val image = if (rendered < MAX_VISION_PAGES) pdf.render(i).also { rendered++ } else null
                            pages += PageContent(i + 1, null, image)
                        }
                    }
                    onProgress(pdf.count, pdf.count)
                    return ExtractedDocument(name, PDF, pages, true)
                } finally {
                    pdf.close()
                }
            }
        } finally {
            copy.delete()
        }
    }
}

/**
 * The text and pixels of PDF pages. Page text comes from
 * PdfRenderer.Page.getTextContents (API 35) or, on Android 12 to 14, from
 * PdfRendererPreV, which the PDF mainline module adds at S extension 13.
 * Without either, [text] is null and every page is read as an image.
 */
private abstract class PdfPages {
    abstract val count: Int
    abstract fun text(index: Int): String?
    abstract fun render(index: Int): ByteArray
    abstract fun close()

    protected fun jpeg(width: Int, height: Int, draw: (Bitmap, Matrix) -> Unit): ByteArray {
        val scale = RENDER_SIDE.toFloat() / maxOf(width, height)
        val bitmap = Bitmap.createBitmap(
            (width * scale).toInt().coerceAtLeast(1), (height * scale).toInt().coerceAtLeast(1), Bitmap.Config.ARGB_8888,
        )
        // Pages are transparent where nothing is drawn; JPEG would make that black.
        bitmap.eraseColor(Color.WHITE)
        draw(bitmap, Matrix().apply { setScale(scale, scale) })
        val out = ByteArrayOutputStream()
        bitmap.compress(Bitmap.CompressFormat.JPEG, 88, out)
        bitmap.recycle()
        return out.toByteArray()
    }

    companion object {
        /** Long edge of a rendered page, as for photos (Media.normalizeImage). */
        private const val RENDER_SIDE = 1024

        fun open(fd: ParcelFileDescriptor): PdfPages = when {
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.VANILLA_ICE_CREAM -> Platform(fd)
            SdkExtensions.getExtensionVersion(Build.VERSION_CODES.S) >= 13 -> PreV(fd)
            else -> RenderOnly(fd)
        }
    }

    @android.annotation.SuppressLint("NewApi")
    private class Platform(fd: ParcelFileDescriptor) : PdfPages() {
        private val renderer = PdfRenderer(fd)
        override val count get() = renderer.pageCount
        override fun text(index: Int) = renderer.openPage(index).use { p -> p.textContents.joinToString("\n") { it.text } }
        override fun render(index: Int) = renderer.openPage(index).use { p ->
            jpeg(p.width, p.height) { b, m -> p.render(b, null, m, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY) }
        }
        override fun close() = renderer.close()
    }

    @android.annotation.SuppressLint("NewApi")
    private class PreV(fd: ParcelFileDescriptor) : PdfPages() {
        private val renderer = PdfRendererPreV(fd)
        override val count get() = renderer.pageCount
        override fun text(index: Int) = renderer.openPage(index).use { p -> p.textContents.joinToString("\n") { it.text } }
        override fun render(index: Int) = renderer.openPage(index).use { p ->
            jpeg(p.width, p.height) { b, m -> p.render(b, null, m, RenderParams.Builder(RenderParams.RENDER_MODE_FOR_DISPLAY).build()) }
        }
        override fun close() = renderer.close()
    }

    private class RenderOnly(fd: ParcelFileDescriptor) : PdfPages() {
        private val renderer = PdfRenderer(fd)
        override val count get() = renderer.pageCount
        override fun text(index: Int): String? = null
        override fun render(index: Int) = renderer.openPage(index).use { p ->
            jpeg(p.width, p.height) { b, m -> p.render(b, null, m, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY) }
        }
        override fun close() = renderer.close()
    }
}

/** Text file bytes to a String, by byte-order mark or else as UTF-8. */
object TextDecoding {
    /**
     * Null when the bytes are not text: a NUL byte never occurs in UTF-8 or
     * single-byte text, only in binary files and in UTF-16/32, which carry a
     * byte-order mark. UTF-8 that does not decode is read as Windows-1252,
     * the encoding older Windows tools save text in, which maps every byte.
     */
    fun decode(bytes: ByteArray): String? {
        fun startsWith(vararg b: Int) = bytes.size >= b.size && b.indices.all { bytes[it] == b[it].toByte() }
        return when {
            startsWith(0xEF, 0xBB, 0xBF) -> String(bytes, 3, bytes.size - 3, Charsets.UTF_8)
            startsWith(0xFF, 0xFE, 0x00, 0x00) -> String(bytes, 4, bytes.size - 4, Charset.forName("UTF-32LE"))
            startsWith(0x00, 0x00, 0xFE, 0xFF) -> String(bytes, 4, bytes.size - 4, Charset.forName("UTF-32BE"))
            startsWith(0xFF, 0xFE) -> String(bytes, 2, bytes.size - 2, Charsets.UTF_16LE)
            startsWith(0xFE, 0xFF) -> String(bytes, 2, bytes.size - 2, Charsets.UTF_16BE)
            bytes.any { it == 0.toByte() } -> null
            else -> try {
                Charsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes))
                    .toString()
            } catch (_: CharacterCodingException) {
                String(bytes, Charset.forName("windows-1252"))
            }
        }
    }
}

/**
 * The text of a Word (.docx) file: `word/document.xml` inside the zip, read
 * with a pull parser. Paragraphs and table rows end lines, table cells are
 * separated by tabs.
 */
object DocxText {
    private const val W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

    fun extract(input: InputStream, parser: XmlPullParser): String {
        val zip = ZipInputStream(input)
        while (true) {
            val entry = requireNotNull(zip.nextEntry) { "This Word file has no document text." }
            if (entry.name == "word/document.xml") break
        }
        parser.setFeature(XmlPullParser.FEATURE_PROCESS_NAMESPACES, true)
        parser.setInput(zip, null)
        val out = StringBuilder()
        var inText = false
        var cellsInRow = 0
        while (true) {
            when (parser.next()) {
                XmlPullParser.END_DOCUMENT -> break
                XmlPullParser.START_TAG -> if (parser.namespace == W) {
                    when (parser.name) {
                        "t" -> inText = true
                        "tab" -> out.append('\t')
                        "br", "cr" -> out.append('\n')
                        "tr" -> cellsInRow = 0
                        "tc" -> if (cellsInRow++ > 0) out.append('\t')
                    }
                }
                XmlPullParser.END_TAG -> if (parser.namespace == W) {
                    when (parser.name) {
                        "t" -> inText = false
                        // A paragraph inside a table cell ends at the cell.
                        "p" -> if (cellsInRow == 0) out.append('\n')
                        "tr" -> {
                            out.append('\n')
                            cellsInRow = 0
                        }
                    }
                }
                XmlPullParser.TEXT -> if (inText) out.append(parser.text)
            }
        }
        return out.toString().trim()
    }
}

/**
 * Splits page text into overlapping passages for retrieval. A passage ends
 * at the last paragraph break, else line break, else sentence end, else
 * space within its last third, so passages rarely cut a sentence; the
 * overlap carries the context across the cut when they do.
 */
object Chunker {
    const val SIZE = 1200
    const val OVERLAP = 150

    fun chunk(text: String, size: Int = SIZE, overlap: Int = OVERLAP): List<String> {
        val t = text.trim()
        if (t.isEmpty()) return emptyList()
        if (t.length <= size) return listOf(t)
        val out = ArrayList<String>()
        var start = 0
        while (start < t.length) {
            var end = minOf(start + size, t.length)
            if (end < t.length) end = breakBefore(t, start, end)
            out += t.substring(start, end).trim()
            if (end >= t.length) break
            // Always moves forward, even when the break left less than the overlap.
            start = maxOf(end - overlap, start + 1)
            while (start < end && !t[start - 1].isWhitespace()) start++
        }
        return out.filter { it.isNotEmpty() }
    }

    private fun breakBefore(t: String, start: Int, end: Int): Int {
        val floor = start + (end - start) * 2 / 3
        for (marker in listOf("\n\n", "\n", ". ", "? ", "! ", " ")) {
            val at = t.lastIndexOf(marker, end - marker.length)
            if (at >= floor) return at + marker.length
        }
        return end
    }
}
