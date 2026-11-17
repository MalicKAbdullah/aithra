package dev.abdullah.aithra

import android.content.ContentValues
import android.database.sqlite.SQLiteDatabase
import android.util.Log
import dev.abdullah.aithra.engine.Embedder
import java.util.UUID

/**
 * Documents attached to chats, in ChatDb's encrypted store: names, page
 * text and passages are sealed like messages. A document is stored when it
 * is picked, unattached (conv_id NULL), and joins its chat with the message
 * that sends it. Passages ([Chunker]) are embedded for retrieval when the
 * EmbeddingGemma model is on the phone.
 */
class DocumentStore(private val chat: ChatDb) {
    companion object {
        /** An unattached document older than this was abandoned (app closed with it in the composer). */
        private const val ABANDONED_MS = 24 * 60 * 60 * 1000L

        fun createTables(db: SQLiteDatabase) {
            db.execSQL(
                """CREATE TABLE documents(
                    id TEXT PRIMARY KEY, conv_id TEXT, msg_id INTEGER, name BLOB NOT NULL, mime TEXT NOT NULL,
                    pages INTEGER NOT NULL, paged INTEGER NOT NULL, chars INTEGER NOT NULL, created INTEGER NOT NULL,
                    summary BLOB, summary_parts BLOB)""",
            )
            db.execSQL("CREATE INDEX documents_conv ON documents(conv_id)")
            // text is NULL for a scanned page until the vision model has read
            // its image; image is NULL once read, or when it was never rendered.
            db.execSQL(
                """CREATE TABLE doc_pages(doc_id TEXT NOT NULL, page INTEGER NOT NULL, text BLOB, image TEXT,
                    PRIMARY KEY(doc_id, page))""",
            )
            db.execSQL(
                """CREATE TABLE doc_chunks(doc_id TEXT NOT NULL, ord INTEGER NOT NULL, page INTEGER NOT NULL,
                    text BLOB NOT NULL, vec BLOB, PRIMARY KEY(doc_id, ord))""",
            )
            db.execSQL("CREATE TABLE citations(msg_id INTEGER NOT NULL, doc_id TEXT NOT NULL, ord INTEGER NOT NULL)")
            db.execSQL("CREATE INDEX citations_msg ON citations(msg_id)")
        }

        /** Removes [ids] with their pages, passages, page images and citations. Inside a transaction. */
        fun deleteIn(db: SQLiteDatabase, ids: List<String>) {
            for (id in ids) {
                db.rawQuery("SELECT image FROM doc_pages WHERE doc_id = ? AND image IS NOT NULL", arrayOf(id)).use { c ->
                    while (c.moveToNext()) db.delete("media", "id = ?", arrayOf(c.getString(0)))
                }
                db.delete("doc_pages", "doc_id = ?", arrayOf(id))
                db.delete("doc_chunks", "doc_id = ?", arrayOf(id))
                db.delete("citations", "doc_id = ?", arrayOf(id))
                db.delete("documents", "id = ?", arrayOf(id))
            }
        }

        fun idsOfConversation(db: SQLiteDatabase, convId: String): List<String> =
            db.rawQuery("SELECT id FROM documents WHERE conv_id = ?", arrayOf(convId))
                .use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }

        /** Documents sent with messages of [convId] from [fromSeq] on, except [keep]. */
        fun idsFromSeq(db: SQLiteDatabase, convId: String, fromSeq: Int, keep: Set<String>): List<String> =
            db.rawQuery(
                "SELECT d.id FROM documents d JOIN messages m ON m.id = d.msg_id WHERE m.conv_id = ? AND m.seq >= ?",
                arrayOf(convId, fromSeq.toString()),
            ).use { c -> buildList { while (c.moveToNext()) c.getString(0).let { if (it !in keep) add(it) } } }
    }

    private val readable get() = chat.readableDatabase
    private val writable get() = chat.writableDatabase

    /** Drops documents picked but never sent. */
    fun sweepAbandoned(now: Long) = writable.transaction {
        val ids = rawQuery(
            "SELECT id FROM documents WHERE conv_id IS NULL AND created < ?",
            arrayOf((now - ABANDONED_MS).toString()),
        ).use { c -> buildList { while (c.moveToNext()) add(c.getString(0)) } }
        deleteIn(this, ids)
    }

    /** Stores [doc] unattached and returns its row (see [row]). */
    fun put(doc: ExtractedDocument, now: Long): Map<String, Any?> {
        val id = UUID.randomUUID().toString()
        val start = System.nanoTime()
        var chunks = 0
        writable.transaction {
            var chars = 0
            for (p in doc.pages) {
                val imageId = p.image?.let { jpeg ->
                    "doc-$id-p${p.page}".also { chat.putImageIn(this, it, jpeg, Media.thumbnail(jpeg)) }
                }
                insertOrThrow("doc_pages", null, ContentValues().apply {
                    put("doc_id", id)
                    put("page", p.page)
                    if (p.text == null) putNull("text") else put("text", chat.sealText(p.text))
                    put("image", imageId)
                })
                if (p.text != null) {
                    chars += p.text.length
                    chunks += insertChunks(this, id, p.page, p.text)
                }
            }
            insertOrThrow("documents", null, ContentValues().apply {
                put("id", id)
                put("name", chat.sealText(doc.name))
                put("mime", doc.mime)
                put("pages", doc.pages.size)
                put("paged", if (doc.paged) 1 else 0)
                put("chars", chars)
                put("created", now)
            })
        }
        Log.i(Documents.LOG_TAG, "chunk+store chunks=$chunks ms=${(System.nanoTime() - start) / 1_000_000}")
        return document(id)!!
    }

    /** Splits [text] into passages of [docId] after its last one; returns how many. */
    private fun insertChunks(db: SQLiteDatabase, docId: String, page: Int, text: String): Int {
        var ord = db.rawQuery("SELECT COALESCE(MAX(ord), -1) + 1 FROM doc_chunks WHERE doc_id = ?", arrayOf(docId))
            .use { c -> c.moveToFirst(); c.getInt(0) }
        val passages = Chunker.chunk(text)
        for (passage in passages) {
            db.insertOrThrow("doc_chunks", null, ContentValues().apply {
                put("doc_id", docId)
                put("ord", ord++)
                put("page", page)
                put("text", chat.sealText(passage))
            })
        }
        return passages.size
    }

    private val columns =
        "id, conv_id, msg_id, name, mime, pages, paged, chars, created, summary, summary_parts, " +
            "(SELECT COUNT(*) FROM doc_pages p WHERE p.doc_id = documents.id AND p.text IS NULL AND p.image IS NOT NULL), " +
            "(SELECT COUNT(*) FROM doc_pages p WHERE p.doc_id = documents.id AND p.text IS NULL AND p.image IS NULL)"

    /**
     * A document as Dart sees it. `unreadPages` are scans waiting for the
     * vision model; `unreadablePages` are scans past [Documents.MAX_VISION_PAGES]
     * or ones the model found no text on.
     */
    private fun row(c: android.database.Cursor): Map<String, Any?> = mapOf(
        "id" to c.getString(0),
        "convId" to c.getString(1),
        "msgId" to if (c.isNull(2)) null else c.getLong(2),
        "name" to chat.openText(c.getBlob(3)),
        "mime" to c.getString(4),
        "pages" to c.getInt(5),
        "paged" to (c.getInt(6) == 1),
        "chars" to c.getInt(7),
        "created" to c.getLong(8),
        "summary" to if (c.isNull(9)) null else chat.openText(c.getBlob(9)),
        "summaryParts" to if (c.isNull(10)) null else chat.openText(c.getBlob(10)),
        "unreadPages" to c.getInt(11),
        "unreadablePages" to c.getInt(12),
    )

    fun document(id: String): Map<String, Any?>? =
        readable.rawQuery("SELECT $columns FROM documents WHERE id = ?", arrayOf(id))
            .use { c -> if (c.moveToFirst()) row(c) else null }

    /** The documents sent in [convId], oldest first. */
    fun ofConversation(convId: String): List<Map<String, Any?>> =
        readable.rawQuery("SELECT $columns FROM documents WHERE conv_id = ? ORDER BY created", arrayOf(convId))
            .use { c -> buildList { while (c.moveToNext()) add(row(c)) } }

    fun attach(convId: String, msgId: Long, ids: List<String>) = writable.transaction {
        for (id in ids) {
            update("documents", ContentValues().apply {
                put("conv_id", convId)
                put("msg_id", msgId)
            }, "id = ?", arrayOf(id))
        }
    }

    fun delete(id: String) = writable.transaction { deleteIn(this, listOf(id)) }

    /** Pages with text, in order: `page`, `text`. */
    fun pages(id: String): List<Map<String, Any?>> =
        readable.rawQuery("SELECT page, text FROM doc_pages WHERE doc_id = ? AND text IS NOT NULL ORDER BY page", arrayOf(id))
            .use { c -> buildList { while (c.moveToNext()) add(mapOf("page" to c.getInt(0), "text" to chat.openText(c.getBlob(1)))) } }

    /** Scanned pages waiting for the vision model: `page` and the `image` id in media. */
    fun unreadPages(id: String): List<Map<String, Any?>> =
        readable.rawQuery(
            "SELECT page, image FROM doc_pages WHERE doc_id = ? AND text IS NULL AND image IS NOT NULL ORDER BY page",
            arrayOf(id),
        ).use { c -> buildList { while (c.moveToNext()) add(mapOf("page" to c.getInt(0), "image" to c.getString(1))) } }

    /**
     * Stores what the vision model read on a scanned page and frees its
     * image; empty [text] marks the page as having nothing to read.
     */
    fun setPageText(id: String, page: Int, text: String) = writable.transaction {
        val image = rawQuery("SELECT image FROM doc_pages WHERE doc_id = ? AND page = ?", arrayOf(id, page.toString()))
            .use { c -> if (c.moveToFirst() && !c.isNull(0)) c.getString(0) else null }
        image?.let { delete("media", "id = ?", arrayOf(it)) }
        val clean = text.trim()
        update("doc_pages", ContentValues().apply {
            if (clean.isEmpty()) putNull("text") else put("text", chat.sealText(clean))
            putNull("image")
        }, "doc_id = ? AND page = ?", arrayOf(id, page.toString()))
        if (clean.isNotEmpty()) {
            insertChunks(this, id, page, clean)
            execSQL("UPDATE documents SET chars = chars + ? WHERE id = ?", arrayOf<Any>(clean.length, id))
        }
    }

    fun setSummary(id: String, parts: String?, summary: String?) {
        writable.update("documents", ContentValues().apply {
            if (parts == null) putNull("summary_parts") else put("summary_parts", chat.sealText(parts))
            if (summary == null) putNull("summary") else put("summary", chat.sealText(summary))
        }, "id = ?", arrayOf(id))
    }

    /** Documents whose summary was started and not finished, to resume. */
    fun pendingSummaries(): List<Map<String, Any?>> =
        readable.rawQuery(
            "SELECT $columns FROM documents WHERE summary IS NULL AND summary_parts IS NOT NULL AND conv_id IS NOT NULL",
            null,
        ).use { c -> buildList { while (c.moveToNext()) add(row(c)) } }

    private fun passage(c: android.database.Cursor, score: Double?) = mapOf(
        "docId" to c.getString(0),
        "ord" to c.getInt(1),
        "page" to c.getInt(2),
        "text" to chat.openText(c.getBlob(3)),
        "score" to score,
    )

    /** Passages of [ids] in reading order, as many as [limit]. */
    fun passagesInOrder(ids: List<String>, limit: Int): List<Map<String, Any?>> {
        if (ids.isEmpty()) return emptyList()
        val marks = ids.joinToString(",") { "?" }
        return readable.rawQuery(
            "SELECT doc_id, ord, page, text FROM doc_chunks WHERE doc_id IN ($marks) ORDER BY doc_id, page, ord LIMIT $limit",
            ids.toTypedArray(),
        ).use { c -> buildList { while (c.moveToNext()) add(passage(c, null)) } }
    }

    fun passage(docId: String, ord: Int): Map<String, Any?>? =
        readable.rawQuery("SELECT doc_id, ord, page, text FROM doc_chunks WHERE doc_id = ? AND ord = ?", arrayOf(docId, ord.toString()))
            .use { c -> if (c.moveToFirst()) passage(c, null) else null }

    /**
     * Embeds up to [limit] passages of [ids] that have no vector yet;
     * returns how many (0 once all are done).
     */
    private fun index(embedder: Embedder, modelPath: String, ids: List<String>, limit: Int): Int {
        val pending = readable.rawQuery(
            "SELECT doc_id, ord, text FROM doc_chunks WHERE vec IS NULL AND doc_id IN (${ids.joinToString(",") { "?" }}) LIMIT $limit",
            ids.toTypedArray(),
        ).use { c -> buildList { while (c.moveToNext()) add(Triple(c.getString(0), c.getInt(1), chat.openText(c.getBlob(2)))) } }
        if (pending.isEmpty()) return 0
        val vecs = embedder.embed(modelPath, pending.map { Embedder.document(it.third) })
        writable.transaction {
            val stmt = compileStatement("UPDATE doc_chunks SET vec = ? WHERE doc_id = ? AND ord = ?")
            pending.zip(vecs).forEach { (p, v) ->
                stmt.bindBlob(1, chat.packVector(v))
                stmt.bindString(2, p.first)
                stmt.bindLong(3, p.second.toLong())
                stmt.executeUpdateDelete()
            }
        }
        return pending.size
    }

    /**
     * The passages of [ids] closest in meaning to [query], best first.
     * Passages not yet embedded are embedded first, so a question asked
     * right after attaching still searches the whole document.
     */
    fun search(embedder: Embedder, modelPath: String, ids: List<String>, query: String, limit: Int): List<Map<String, Any?>> {
        if (ids.isEmpty()) return emptyList()
        val start = System.nanoTime()
        var missing = 0
        while (true) {
            val n = index(embedder, modelPath, ids, 16)
            if (n == 0) break
            missing += n
        }
        val indexed = System.nanoTime()
        val q = embedder.embed(modelPath, listOf(Embedder.query(query.trim()))).single()
        val embedded = System.nanoTime()
        val marks = ids.joinToString(",") { "?" }
        val scored = readable.rawQuery(
            "SELECT doc_id, ord, vec FROM doc_chunks WHERE doc_id IN ($marks) AND vec IS NOT NULL",
            ids.toTypedArray(),
        ).use { c ->
            buildList {
                while (c.moveToNext()) {
                    val v = chat.unpackVector(c.getBlob(2))
                    var s = 0f
                    for (i in q.indices) s += q[i] * v[i]
                    add(Triple(c.getString(0), c.getInt(1), s))
                }
            }
        }
        val found = scored.sortedByDescending { it.third }.take(limit).mapNotNull { (doc, ord, score) ->
            passage(doc, ord)?.plus("score" to score.toDouble())
        }
        val end = System.nanoTime()
        Log.i(
            Documents.LOG_TAG,
            "search embeddedAtQuestion=$missing indexMs=${(indexed - start) / 1_000_000} " +
                "queryMs=${(embedded - indexed) / 1_000_000} scoreMs=${(end - embedded) / 1_000_000} " +
                "passages=${scored.size} totalMs=${(end - start) / 1_000_000}",
        )
        return found
    }

    fun putCitations(msgId: Long, cites: List<Map<String, Any?>>) = writable.transaction {
        for (cite in cites) {
            insertOrThrow("citations", null, ContentValues().apply {
                put("msg_id", msgId)
                put("doc_id", cite["docId"] as String)
                put("ord", cite["ord"] as Int)
            })
        }
    }

    /** Every citation in [convId]: `msgId`, `docId`, `ord`, `page`, `name`. */
    fun citations(convId: String): List<Map<String, Any?>> =
        readable.rawQuery(
            "SELECT c.msg_id, c.doc_id, c.ord, k.page, d.name FROM citations c " +
                "JOIN messages m ON m.id = c.msg_id JOIN documents d ON d.id = c.doc_id " +
                "JOIN doc_chunks k ON k.doc_id = c.doc_id AND k.ord = c.ord WHERE m.conv_id = ? ORDER BY c.rowid",
            arrayOf(convId),
        ).use { c ->
            buildList {
                while (c.moveToNext()) {
                    add(mapOf(
                        "msgId" to c.getLong(0), "docId" to c.getString(1), "ord" to c.getInt(2),
                        "page" to c.getInt(3), "name" to chat.openText(c.getBlob(4)),
                    ))
                }
            }
        }
}
