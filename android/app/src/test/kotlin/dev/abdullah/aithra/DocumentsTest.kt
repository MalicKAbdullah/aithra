package dev.abdullah.aithra

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.kxml2.io.KXmlParser
import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.util.zip.ZipEntry
import java.util.zip.ZipOutputStream

class TextDecodingTest {
    private fun bytes(vararg b: Int) = ByteArray(b.size) { b[it].toByte() }

    @Test
    fun plainUtf8() = assertEquals("café ☕", TextDecoding.decode("café ☕".toByteArray(Charsets.UTF_8)))

    @Test
    fun utf8ByteOrderMarkIsDropped() =
        assertEquals("a,b", TextDecoding.decode(bytes(0xEF, 0xBB, 0xBF) + "a,b".toByteArray()))

    @Test
    fun utf16ByMark() {
        assertEquals("hé", TextDecoding.decode(bytes(0xFF, 0xFE) + "hé".toByteArray(Charsets.UTF_16LE)))
        assertEquals("hé", TextDecoding.decode(bytes(0xFE, 0xFF) + "hé".toByteArray(Charsets.UTF_16BE)))
    }

    @Test
    fun utf32ByMark() =
        assertEquals("x", TextDecoding.decode(bytes(0xFF, 0xFE, 0, 0) + "x".toByteArray(charset("UTF-32LE"))))

    @Test
    fun invalidUtf8IsReadAsWindows1252() =
        assertEquals("naïve €5", TextDecoding.decode("naïve €5".toByteArray(charset("windows-1252"))))

    @Test
    fun binaryIsNotText() = assertNull(TextDecoding.decode(bytes(0x50, 0x4B, 0x03, 0x04, 0x00, 0x00)))

    @Test
    fun emptyFileIsEmptyText() = assertEquals("", TextDecoding.decode(ByteArray(0)))
}

class DocxTextTest {
    private fun docx(body: String, extra: Map<String, String> = emptyMap()): ByteArray {
        val xml = """<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>$body</w:body></w:document>"""
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            for ((name, content) in extra + ("word/document.xml" to xml)) {
                zip.putNextEntry(ZipEntry(name))
                zip.write(content.toByteArray())
                zip.closeEntry()
            }
        }
        return out.toByteArray()
    }

    private fun extract(bytes: ByteArray) = DocxText.extract(ByteArrayInputStream(bytes), KXmlParser())

    @Test
    fun paragraphsAndRuns() = assertEquals(
        "Ferry times\nThe first ferry leaves at nine.",
        extract(
            docx(
                "<w:p><w:r><w:t>Ferry times</w:t></w:r></w:p>" +
                    "<w:p><w:r><w:t xml:space=\"preserve\">The first ferry </w:t></w:r><w:r><w:t>leaves at nine.</w:t></w:r></w:p>",
                extra = mapOf("[Content_Types].xml" to "<Types/>", "word/styles.xml" to "<styles/>"),
            ),
        ),
    )

    @Test
    fun tabsAndBreaks() = assertEquals(
        "a\tb\nc",
        extract(docx("<w:p><w:r><w:t>a</w:t><w:tab/><w:t>b</w:t><w:br/><w:t>c</w:t></w:r></w:p>")),
    )

    @Test
    fun tablesBecomeTabSeparatedRows() = assertEquals(
        "Port\tTime\nOban\t09:00",
        extract(
            docx(
                "<w:tbl>" +
                    "<w:tr><w:tc><w:p><w:r><w:t>Port</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>Time</w:t></w:r></w:p></w:tc></w:tr>" +
                    "<w:tr><w:tc><w:p><w:r><w:t>Oban</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>09:00</w:t></w:r></w:p></w:tc></w:tr>" +
                    "</w:tbl>",
            ),
        ),
    )

    @Test
    fun entitiesAreDecoded() =
        assertEquals("Tom & Jerry <3", extract(docx("<w:p><w:r><w:t>Tom &amp; Jerry &lt;3</w:t></w:r></w:p>")))

    @Test(expected = IllegalArgumentException::class)
    fun aZipWithoutDocumentXmlIsRejected() {
        val out = ByteArrayOutputStream()
        ZipOutputStream(out).use { zip ->
            zip.putNextEntry(ZipEntry("xl/workbook.xml"))
            zip.write("<workbook/>".toByteArray())
            zip.closeEntry()
        }
        extract(out.toByteArray())
    }
}

class ChunkerTest {
    @Test
    fun shortTextIsOnePassage() = assertEquals(listOf("A short note."), Chunker.chunk("  A short note.  "))

    @Test
    fun emptyTextHasNoPassages() = assertEquals(emptyList<String>(), Chunker.chunk(" \n "))

    @Test
    fun passagesStayWithinSizeAndCoverEveryWord() {
        val words = (1..2000).map { "w$it" }
        val text = words.chunked(12).joinToString(". ") { it.joinToString(" ") }
        val passages = Chunker.chunk(text)
        assertTrue(passages.size > 1)
        passages.forEach { assertTrue(it.length <= Chunker.SIZE) }
        val seen = passages.flatMap { it.split(Regex("[ .]+")) }.toSet()
        words.forEach { assertTrue("$it missing", it in seen) }
    }

    @Test
    fun consecutivePassagesOverlap() {
        val text = (1..600).joinToString(" ") { "word$it" }
        val passages = Chunker.chunk(text)
        for (i in 1 until passages.size) {
            val lastWords = passages[i - 1].split(' ').takeLast(3)
            assertTrue("passage $i does not repeat the end of ${i - 1}", passages[i].contains(lastWords.first()))
        }
    }

    @Test
    fun cutsPreferParagraphBreaks() {
        val first = "a".repeat(900)
        val text = "$first\n\n" + "b ".repeat(400)
        assertEquals(first, Chunker.chunk(text).first())
    }

    @Test
    fun textWithoutSpacesStillEnds() {
        val passages = Chunker.chunk("x".repeat(5000))
        assertTrue(passages.size in 4..6)
        passages.forEach { assertTrue(it.length <= Chunker.SIZE) }
    }
}
