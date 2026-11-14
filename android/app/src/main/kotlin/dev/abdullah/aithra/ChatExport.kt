package dev.abdullah.aithra

import android.content.Context
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Typeface
import android.graphics.pdf.PdfDocument
import android.text.Layout
import android.text.StaticLayout
import android.text.TextPaint
import java.io.File
import java.text.DateFormat
import java.util.Date

/**
 * A chat written out for sharing, as Markdown or as an A4 PDF drawn with
 * Android's own [PdfDocument]. The files are plaintext, so they live in one
 * cache folder that is emptied before each export and at every launch: a
 * share target reads the file after the chooser returns, so it cannot be
 * deleted right away.
 */
object ChatExport {
    private const val PAGE_WIDTH = 595 // A4 in PostScript points
    private const val PAGE_HEIGHT = 842
    private const val MARGIN = 56f

    fun dir(context: Context) = File(context.cacheDir, "export")

    fun clear(context: Context) {
        dir(context).listFiles()?.forEach { it.delete() }
    }

    private fun fresh(context: Context, name: String, extension: String): File {
        clear(context)
        val safe = name.replace(Regex("[^\\p{L}\\p{N} ._-]"), "_").trim().take(80).ifEmpty { "Chat" }
        return File(dir(context).apply { mkdirs() }, "$safe.$extension")
    }

    fun markdown(context: Context, name: String, text: String): String =
        fresh(context, name, "md").apply { writeText(text) }.path

    /**
     * [entries] are the messages, oldest first: `role` (`user` or `model`),
     * `created` (epoch ms) and `blocks`, each a `kind` (`heading`, `text`,
     * `item`, `quote`, `code`, `rule`) and its `text`.
     */
    fun pdf(context: Context, name: String, title: String, entries: List<Map<String, Any?>>): String {
        val file = fresh(context, name, "pdf")
        val doc = PdfDocument()
        try {
            Writer(doc).apply {
                paragraph(title, titlePaint, gapAfter = 18f)
                val date = DateFormat.getDateTimeInstance(DateFormat.MEDIUM, DateFormat.SHORT)
                for (e in entries) {
                    val who = if (e["role"] == "user") "You" else "Aithra"
                    val time = date.format(Date((e["created"] as Number).toLong()))
                    paragraph("$who · $time", rolePaint, gapAfter = 4f)
                    @Suppress("UNCHECKED_CAST")
                    for (b in e["blocks"] as List<Map<String, Any?>>) block(b["kind"] as String, b["text"] as String)
                    space(14f)
                }
                finish()
            }
            file.outputStream().use(doc::writeTo)
        } finally {
            doc.close()
        }
        return file.path
    }

    private val titlePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 18f
        typeface = Typeface.DEFAULT_BOLD
        color = Color.BLACK
    }
    private val rolePaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 9f
        typeface = Typeface.DEFAULT_BOLD
        color = Color.rgb(0x5F, 0x63, 0x68)
    }
    private val bodyPaint = TextPaint(Paint.ANTI_ALIAS_FLAG).apply {
        textSize = 11f
        color = Color.BLACK
    }
    private val headingPaint = TextPaint(bodyPaint).apply {
        textSize = 13f
        typeface = Typeface.DEFAULT_BOLD
    }
    private val quotePaint = TextPaint(bodyPaint).apply {
        typeface = Typeface.create(Typeface.DEFAULT, Typeface.ITALIC)
        color = Color.rgb(0x3C, 0x40, 0x43)
    }
    private val codePaint = TextPaint(bodyPaint).apply {
        textSize = 9.5f
        typeface = Typeface.MONOSPACE
    }
    private val rulePaint = Paint().apply { color = Color.rgb(0xDA, 0xDC, 0xE0) }

    /** Lays text out top to bottom, starting a page whenever one fills. */
    private class Writer(private val doc: PdfDocument) {
        private val width = (PAGE_WIDTH - 2 * MARGIN).toInt()
        private var page: PdfDocument.Page? = null
        private var y = MARGIN

        private fun current(): PdfDocument.Page = page ?: doc.startPage(
            PdfDocument.PageInfo.Builder(PAGE_WIDTH, PAGE_HEIGHT, doc.pages.size + 1).create(),
        ).also {
            page = it
            y = MARGIN
        }

        private fun nextPage() {
            page?.let(doc::finishPage)
            page = null
        }

        fun space(h: Float) {
            y += h
        }

        fun block(kind: String, text: String) = when (kind) {
            "heading" -> paragraph(text, headingPaint, gapAfter = 6f)
            "item" -> paragraph("•  $text", bodyPaint, gapAfter = 3f, indent = 10)
            "quote" -> paragraph(text, quotePaint, gapAfter = 6f, indent = 14)
            "code" -> paragraph(text, codePaint, gapAfter = 6f, indent = 8)
            "rule" -> {
                current()
                page!!.canvas.drawRect(MARGIN, y + 4, MARGIN + width, y + 5, rulePaint)
                space(12f)
            }
            else -> paragraph(text, bodyPaint, gapAfter = 6f)
        }

        fun paragraph(text: String, paint: TextPaint, gapAfter: Float, indent: Int = 0) {
            val layout = StaticLayout.Builder.obtain(text, 0, text.length, paint, width - indent)
                .setAlignment(Layout.Alignment.ALIGN_NORMAL)
                .setLineSpacing(0f, 1.15f)
                .build()
            var line = 0
            while (line < layout.lineCount) {
                val canvas = current().canvas
                val room = PAGE_HEIGHT - MARGIN - y
                var last = line
                while (last + 1 < layout.lineCount &&
                    layout.getLineBottom(last + 1) - layout.getLineTop(line) <= room
                ) {
                    last++
                }
                val top = layout.getLineTop(line).toFloat()
                val height = layout.getLineBottom(last) - top
                if (height > room && y > MARGIN) {
                    nextPage()
                    continue
                }
                canvas.save()
                canvas.clipRect(MARGIN + indent, y, MARGIN + width, y + height)
                canvas.translate(MARGIN + indent, y - top)
                layout.draw(canvas)
                canvas.restore()
                y += height
                line = last + 1
                if (line < layout.lineCount) nextPage()
            }
            space(gapAfter)
        }

        fun finish() = nextPage()
    }
}
