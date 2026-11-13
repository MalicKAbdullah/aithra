package dev.abdullah.aithra

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import dev.abdullah.aithra.engine.Embedder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Encrypted chat store on Android's built-in SQLite.
 *
 * Every text column (titles, messages, summaries, drafts) and every image is
 * AES-256-GCM encrypted with the app's data key, in core_crypto's
 * `EncryptedPayload` layout (salt 32 | nonce 12 | ciphertext+tag), so Dart can
 * decrypt the same bytes. The key lives in core_storage (Android Keystore
 * backed) and is handed over by Dart on [open]; it is never written here.
 *
 * The chat-list search box matches word prefixes of titles through a blind
 * index: each prefix is stored only as a keyed HMAC. Cross-chat recall is
 * semantic: each message's EmbeddingGemma vector is stored encrypted and
 * compared by cosine similarity at query time (see [indexVectors] and
 * [recall]); without the embedding model, recall is off.
 */
class ChatDb(context: Context) : SQLiteOpenHelper(context, "aithra.db", null, 3) {
    private companion object {
        /** Enough for two lines of preview after Markdown is stripped. */
        const val PREVIEW_CHARS = 240

        /** Cosine similarity below which a past message is not recalled. */
        const val RECALL_THRESHOLD = 0.45f

        /** Similarity a message needs to show up in search. */
        const val SEARCH_THRESHOLD = 0.4f

        /** Characters of a message that are embedded. */
        const val EMBED_CHARS = 1500
    }

    private var key: SecretKeySpec? = null
    private var termKey: SecretKeySpec? = null
    private val random = SecureRandom()

    override fun onCreate(db: SQLiteDatabase) {
        db.execSQL(
            """CREATE TABLE conversations(
                id TEXT PRIMARY KEY, title BLOB NOT NULL, created INTEGER NOT NULL,
                updated INTEGER NOT NULL, pinned INTEGER NOT NULL DEFAULT 0,
                summary BLOB, summarized_upto INTEGER NOT NULL DEFAULT 0,
                draft BLOB, scroll REAL NOT NULL DEFAULT 0, message_count INTEGER NOT NULL DEFAULT 0)""",
        )
        db.execSQL(
            """CREATE TABLE messages(
                id INTEGER PRIMARY KEY AUTOINCREMENT, conv_id TEXT NOT NULL, seq INTEGER NOT NULL,
                role TEXT NOT NULL, content BLOB NOT NULL, images TEXT NOT NULL DEFAULT '',
                created INTEGER NOT NULL, stats TEXT, length INTEGER NOT NULL DEFAULT 0,
                tokens INTEGER, tokens_model TEXT)""",
        )
        db.execSQL("CREATE UNIQUE INDEX messages_conv_seq ON messages(conv_id, seq)")
        db.execSQL("CREATE TABLE media(id TEXT PRIMARY KEY, data BLOB NOT NULL, thumb BLOB NOT NULL)")
        createSearchTables(db)
    }

    private fun createSearchTables(db: SQLiteDatabase) {
        db.execSQL("CREATE TABLE title_terms(hash INTEGER NOT NULL, conv_id TEXT NOT NULL)")
        db.execSQL("CREATE INDEX title_terms_hash ON title_terms(hash)")
        db.execSQL("CREATE INDEX title_terms_conv ON title_terms(conv_id)")
        // An empty vec marks a message with no text to embed (images only).
        db.execSQL("CREATE TABLE vectors(msg_id INTEGER PRIMARY KEY, conv_id TEXT NOT NULL, vec BLOB NOT NULL)")
        db.execSQL("CREATE INDEX vectors_conv ON vectors(conv_id)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {
        if (oldVersion < 3) {
            // The token count of each message under the model that counted
            // it, so prompts are planned on exact counts without recounting.
            db.execSQL("ALTER TABLE messages ADD COLUMN tokens INTEGER")
            db.execSQL("ALTER TABLE messages ADD COLUMN tokens_model TEXT")
        }
        if (oldVersion < 2) {
            // Version 1 kept a keyword index of message words; recall is now
            // semantic and the title index has its own table.
            db.execSQL("DROP TABLE IF EXISTS terms")
            createSearchTables(db)
            db.rawQuery("SELECT id, title FROM conversations", null).use { c ->
                while (c.moveToNext()) indexTitle(db, c.getString(0), openText(c.getBlob(1)))
            }
        }
    }

    override fun onConfigure(db: SQLiteDatabase) {
        db.enableWriteAheadLogging()
    }

    fun open(dataKey: ByteArray) {
        key = SecretKeySpec(dataKey, "AES")
        val mac = Mac.getInstance("HmacSHA256").apply { init(SecretKeySpec(dataKey, "HmacSHA256")) }
        termKey = SecretKeySpec(mac.doFinal("aithra-terms".toByteArray()), "HmacSHA256")
        writableDatabase
    }

    // -- Crypto ---------------------------------------------------------------

    private fun seal(plain: ByteArray): ByteArray {
        val salt = ByteArray(32).also(random::nextBytes)
        val nonce = ByteArray(12).also(random::nextBytes)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key!!, GCMParameterSpec(128, nonce))
        return salt + nonce + cipher.doFinal(plain)
    }

    private fun unseal(sealed: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, key!!, GCMParameterSpec(128, sealed, 32, 12))
        return cipher.doFinal(sealed, 44, sealed.size - 44)
    }

    private fun sealText(text: String) = seal(text.toByteArray(Charsets.UTF_8))
    private fun openText(bytes: ByteArray) = String(unseal(bytes), Charsets.UTF_8)

    // -- Blind keyword index ----------------------------------------------------

    private fun termHash(term: String): Long {
        val mac = Mac.getInstance("HmacSHA256").apply { init(termKey!!) }
        return ByteBuffer.wrap(mac.doFinal(term.toByteArray(Charsets.UTF_8)), 0, 8).long
    }

    private fun indexTitle(db: SQLiteDatabase, convId: String, title: String) {
        db.delete("title_terms", "conv_id = ?", arrayOf(convId))
        val stmt = db.compileStatement("INSERT INTO title_terms(hash, conv_id) VALUES(?,?)")
        for (prefix in TitleTerms.words(title).flatMap(TitleTerms::prefixes).toSet()) {
            stmt.bindLong(1, termHash(prefix))
            stmt.bindString(2, convId)
            stmt.executeInsert()
        }
    }

    // -- Conversations ----------------------------------------------------------

    private fun conversationRow(c: android.database.Cursor): Map<String, Any?> = mapOf(
        "id" to c.getString(0),
        "title" to openText(c.getBlob(1)),
        "created" to c.getLong(2),
        "updated" to c.getLong(3),
        "pinned" to (c.getInt(4) == 1),
        "summary" to if (c.isNull(5)) null else openText(c.getBlob(5)),
        "summarizedUpto" to c.getInt(6),
        "draft" to if (c.isNull(7)) null else openText(c.getBlob(7)),
        "scroll" to c.getDouble(8),
        "messageCount" to c.getInt(9),
        "preview" to if (c.isNull(10)) null else openText(c.getBlob(10)).take(PREVIEW_CHARS),
        "previewRole" to c.getString(11),
    )

    // The latest message rides along for the list preview; the
    // (conv_id, seq) index makes each lookup a single index seek.
    private val conversationColumns =
        "id, title, created, updated, pinned, summary, summarized_upto, draft, scroll, message_count, " +
            "(SELECT content FROM messages m WHERE m.conv_id = conversations.id ORDER BY m.seq DESC LIMIT 1), " +
            "(SELECT role FROM messages m WHERE m.conv_id = conversations.id ORDER BY m.seq DESC LIMIT 1)"

    /** Pinned first, then most recently updated. */
    fun listConversations(offset: Int, limit: Int): List<Map<String, Any?>> =
        readableDatabase.rawQuery(
            "SELECT $conversationColumns FROM conversations ORDER BY pinned DESC, updated DESC LIMIT ? OFFSET ?",
            arrayOf(limit.toString(), offset.toString()),
        ).use { c -> buildList { while (c.moveToNext()) add(conversationRow(c)) } }

    fun getConversation(id: String): Map<String, Any?>? =
        readableDatabase.rawQuery("SELECT $conversationColumns FROM conversations WHERE id = ?", arrayOf(id))
            .use { c -> if (c.moveToFirst()) conversationRow(c) else null }

    fun createConversation(id: String, title: String, now: Long) {
        writableDatabase.transaction {
            insertOrThrow("conversations", null, ContentValues().apply {
                put("id", id)
                put("title", sealText(title))
                put("created", now)
                put("updated", now)
            })
            indexTitle(this, id, title)
        }
    }

    fun updateConversation(id: String, fields: Map<String, Any?>) {
        writableDatabase.transaction {
            val values = ContentValues()
            fields["title"]?.let {
                values.put("title", sealText(it as String))
                indexTitle(this, id, it)
            }
            fields["pinned"]?.let { values.put("pinned", if (it as Boolean) 1 else 0) }
            fields["updated"]?.let { values.put("updated", (it as Number).toLong()) }
            if (fields.containsKey("summary")) {
                val s = fields["summary"] as String?
                if (s == null) values.putNull("summary") else values.put("summary", sealText(s))
            }
            fields["summarizedUpto"]?.let { values.put("summarized_upto", it as Int) }
            if (fields.containsKey("draft")) {
                val d = fields["draft"] as String?
                if (d.isNullOrEmpty()) values.putNull("draft") else values.put("draft", sealText(d))
            }
            fields["scroll"]?.let { values.put("scroll", (it as Number).toDouble()) }
            if (values.size() > 0) update("conversations", values, "id = ?", arrayOf(id))
        }
    }

    fun deleteConversation(id: String) {
        writableDatabase.transaction {
            val imageIds = rawQuery("SELECT images FROM messages WHERE conv_id = ?", arrayOf(id)).use { c ->
                buildList { while (c.moveToNext()) addAll(c.getString(0).split(',').filter { it.isNotEmpty() }) }
            }
            imageIds.forEach { delete("media", "id = ?", arrayOf(it)) }
            delete("title_terms", "conv_id = ?", arrayOf(id))
            delete("vectors", "conv_id = ?", arrayOf(id))
            delete("messages", "conv_id = ?", arrayOf(id))
            delete("conversations", "id = ?", arrayOf(id))
        }
        dropVectorCache()
    }

    // -- Messages ---------------------------------------------------------------

    private fun messageRow(c: android.database.Cursor): Map<String, Any?> = mapOf(
        "id" to c.getLong(0),
        "seq" to c.getInt(1),
        "role" to c.getString(2),
        "content" to openText(c.getBlob(3)),
        "images" to c.getString(4).split(',').filter { it.isNotEmpty() },
        "created" to c.getLong(5),
        "stats" to c.getString(6),
        "tokens" to if (c.isNull(7)) null else c.getInt(7),
        "tokensModel" to c.getString(8),
    )

    /** The newest [limit] messages with seq < [beforeSeq], newest first. */
    fun messages(convId: String, beforeSeq: Int, limit: Int): List<Map<String, Any?>> =
        readableDatabase.rawQuery(
            "SELECT id, seq, role, content, images, created, stats, tokens, tokens_model FROM messages WHERE conv_id = ? AND seq < ? ORDER BY seq DESC LIMIT ?",
            arrayOf(convId, beforeSeq.toString(), limit.toString()),
        ).use { c -> buildList { while (c.moveToNext()) add(messageRow(c)) } }

    /** Messages with seq in [fromSeq, toSeq), oldest first. */
    fun messageRange(convId: String, fromSeq: Int, toSeq: Int): List<Map<String, Any?>> =
        readableDatabase.rawQuery(
            "SELECT id, seq, role, content, images, created, stats, tokens, tokens_model FROM messages WHERE conv_id = ? AND seq >= ? AND seq < ? ORDER BY seq ASC",
            arrayOf(convId, fromSeq.toString(), toSeq.toString()),
        ).use { c -> buildList { while (c.moveToNext()) add(messageRow(c)) } }

    /** Appends a message at the end of the conversation; returns its id and seq. */
    fun addMessage(convId: String, role: String, content: String, images: List<String>, stats: String?, now: Long): Map<String, Any?> {
        var result: Map<String, Any?> = emptyMap()
        writableDatabase.transaction {
            val seq = rawQuery("SELECT COALESCE(MAX(seq), -1) + 1 FROM messages WHERE conv_id = ?", arrayOf(convId))
                .use { c -> c.moveToFirst(); c.getInt(0) }
            val id = insertOrThrow("messages", null, ContentValues().apply {
                put("conv_id", convId)
                put("seq", seq)
                put("role", role)
                put("content", sealText(content))
                put("images", images.joinToString(","))
                put("created", now)
                put("stats", stats)
            })
            execSQL(
                "UPDATE conversations SET updated = ?, message_count = message_count + 1 WHERE id = ?",
                arrayOf<Any>(now, convId),
            )
            result = mapOf("id" to id, "seq" to seq)
        }
        return result
    }

    fun updateMessage(id: Long, content: String, stats: String?) {
        writableDatabase.transaction {
            // The text changed, so its vector is stale; the indexer redoes it.
            delete("vectors", "msg_id = ?", arrayOf(id.toString()))
            update("messages", ContentValues().apply {
                put("content", sealText(content))
                put("stats", stats)
                putNull("tokens")
                putNull("tokens_model")
            }, "id = ?", arrayOf(id.toString()))
        }
        dropVectorCache()
    }

    /** Stores token counts (message id → count) made by [model]'s tokenizer. */
    fun setTokens(counts: Map<Long, Int>, model: String) {
        writableDatabase.transaction {
            val stmt = compileStatement("UPDATE messages SET tokens = ?, tokens_model = ? WHERE id = ?")
            for ((id, n) in counts) {
                stmt.bindLong(1, n.toLong())
                stmt.bindString(2, model)
                stmt.bindLong(3, id)
                stmt.executeUpdateDelete()
            }
        }
    }

    /** Deletes every message with seq >= [fromSeq] (edit and regenerate). */
    fun truncate(convId: String, fromSeq: Int) {
        writableDatabase.transaction {
            val ids = rawQuery("SELECT id, images FROM messages WHERE conv_id = ? AND seq >= ?", arrayOf(convId, fromSeq.toString()))
                .use { c -> buildList { while (c.moveToNext()) add(c.getLong(0) to c.getString(1)) } }
            for ((id, images) in ids) {
                delete("vectors", "msg_id = ?", arrayOf(id.toString()))
                images.split(',').filter { it.isNotEmpty() }.forEach { delete("media", "id = ?", arrayOf(it)) }
            }
            delete("messages", "conv_id = ? AND seq >= ?", arrayOf(convId, fromSeq.toString()))
            execSQL(
                "UPDATE conversations SET message_count = (SELECT COUNT(*) FROM messages WHERE conv_id = ?), summarized_upto = MIN(summarized_upto, ?) WHERE id = ?",
                arrayOf<Any>(convId, fromSeq, convId),
            )
        }
        dropVectorCache()
    }

    // -- Media ------------------------------------------------------------------

    fun putImage(id: String, jpeg: ByteArray, thumb: ByteArray) {
        writableDatabase.insertOrThrow("media", null, ContentValues().apply {
            put("id", id)
            put("data", seal(jpeg))
            put("thumb", seal(thumb))
        })
    }

    fun image(id: String, thumb: Boolean): ByteArray? =
        readableDatabase.rawQuery("SELECT ${if (thumb) "thumb" else "data"} FROM media WHERE id = ?", arrayOf(id))
            .use { c -> if (c.moveToFirst()) unseal(c.getBlob(0)) else null }

    // -- Search & recall --------------------------------------------------------

    /** Conversations whose title has a word starting with each word of [query]. */
    fun search(query: String, limit: Int): List<Map<String, Any?>> {
        val words = TitleTerms.words(query).distinct()
        if (words.isEmpty()) return emptyList()
        val db = readableDatabase
        var matches: Set<String>? = null
        for (w in words) {
            val ids = db.rawQuery(
                "SELECT DISTINCT conv_id FROM title_terms WHERE hash = ?",
                arrayOf(termHash(TitleTerms.clipPrefix(w)).toString()),
            ).use { c -> buildSet { while (c.moveToNext()) add(c.getString(0)) } }
            matches = matches?.intersect(ids) ?: ids
            if (matches.isEmpty()) return emptyList()
        }
        val placeholders = matches!!.joinToString(",") { "?" }
        return db.rawQuery(
            "SELECT $conversationColumns FROM conversations WHERE id IN ($placeholders) ORDER BY pinned DESC, updated DESC LIMIT $limit",
            matches.toTypedArray(),
        ).use { c -> buildList { while (c.moveToNext()) add(conversationRow(c)) } }
    }

    private fun packVector(v: FloatArray): ByteArray {
        val buf = ByteBuffer.allocate(v.size * 4).order(ByteOrder.LITTLE_ENDIAN)
        v.forEach { buf.putFloat(it) }
        return seal(buf.array())
    }

    private fun unpackVector(sealed: ByteArray): FloatArray {
        val buf = ByteBuffer.wrap(unseal(sealed)).order(ByteOrder.LITTLE_ENDIAN)
        return FloatArray(buf.remaining() / 4) { buf.getFloat() }
    }

    private class Vec(val msgId: Long, val convId: String, val v: FloatArray)

    /** Decrypted vectors, loaded on the first recall and kept while unchanged. */
    private var vectorCache: MutableList<Vec>? = null

    @Synchronized
    private fun dropVectorCache() {
        vectorCache = null
    }

    @Synchronized
    private fun vectors(): List<Vec> = vectorCache ?: readableDatabase
        .rawQuery("SELECT msg_id, conv_id, vec FROM vectors", null)
        .use { c ->
            buildList {
                while (c.moveToNext()) {
                    val blob = c.getBlob(2)
                    if (blob.isNotEmpty()) add(Vec(c.getLong(0), c.getString(1), unpackVector(blob)))
                }
            }
        }
        .toMutableList()
        .also { vectorCache = it }

    @Synchronized
    private fun cacheVector(v: Vec) {
        vectorCache?.add(v)
    }

    /**
     * Embeds up to [limit] messages that have no vector yet, newest first;
     * returns how many it stored (0 once everything is indexed).
     */
    fun indexVectors(embedder: Embedder, modelPath: String, limit: Int): Int {
        val pending = readableDatabase.rawQuery(
            "SELECT m.id, m.conv_id, m.content FROM messages m LEFT JOIN vectors v ON v.msg_id = m.id " +
                "WHERE v.msg_id IS NULL ORDER BY m.id DESC LIMIT ?",
            arrayOf(limit.toString()),
        ).use { c ->
            buildList { while (c.moveToNext()) add(Triple(c.getLong(0), c.getString(1), openText(c.getBlob(2)).trim())) }
        }
        if (pending.isEmpty()) return 0
        val texts = pending.filter { it.third.isNotEmpty() }
        val vecs = embedder.embed(modelPath, texts.map { Embedder.document(it.third.take(EMBED_CHARS)) })
        val byId = texts.map { it.first }.zip(vecs).toMap()
        writableDatabase.transaction {
            for ((id, conv, _) in pending) {
                val v = byId[id]
                insertWithOnConflict("vectors", null, ContentValues().apply {
                    put("msg_id", id)
                    put("conv_id", conv)
                    put("vec", if (v == null) ByteArray(0) else packVector(v))
                }, SQLiteDatabase.CONFLICT_REPLACE)
            }
        }
        for ((id, conv, _) in pending) byId[id]?.let { cacheVector(Vec(id, conv, it)) }
        return pending.size
    }

    /**
     * Past messages from other conversations closest in meaning to [query],
     * most similar first, above [RECALL_THRESHOLD].
     */
    fun recall(embedder: Embedder, modelPath: String, query: String, excludeConv: String?, limit: Int): List<Map<String, Any?>> {
        if (query.isBlank()) return emptyList()
        val q = embedder.embed(modelPath, listOf(Embedder.query(query.trim().take(EMBED_CHARS)))).single()
        return rankAndLoad(q, excludeConv, limit, RECALL_THRESHOLD)
    }

    /** Messages whose meaning matches [query], best first, one per conversation. */
    fun searchMessages(embedder: Embedder, modelPath: String, query: String, limit: Int): List<Map<String, Any?>> {
        if (query.isBlank()) return emptyList()
        val q = embedder.embed(modelPath, listOf(Embedder.query(query.trim().take(EMBED_CHARS)))).single()
        return rankAndLoad(q, null, limit * 4, SEARCH_THRESHOLD)
            .distinctBy { it["convId"] }
            .take(limit)
    }

    /** How many messages have a vector, of all messages. */
    fun vectorStatus(): Map<String, Any?> = readableDatabase.rawQuery(
        "SELECT (SELECT COUNT(*) FROM vectors), (SELECT COUNT(*) FROM messages)", null,
    ).use { c ->
        c.moveToFirst()
        mapOf("indexed" to c.getInt(0), "total" to c.getInt(1))
    }

    private fun rankAndLoad(q: FloatArray, excludeConv: String?, limit: Int, threshold: Float): List<Map<String, Any?>> {
        val top = vectors()
            .asSequence()
            .filter { it.convId != excludeConv && it.v.size == q.size }
            .map { it to dot(q, it.v) }
            .filter { it.second >= threshold }
            .sortedByDescending { it.second }
            .take(limit)
            .toList()
        val db = readableDatabase
        return top.mapNotNull { (vec, score) ->
            db.rawQuery(
                "SELECT conv_id, role, content, created FROM messages WHERE id = ?",
                arrayOf(vec.msgId.toString()),
            ).use { c ->
                if (!c.moveToFirst()) null else mapOf(
                    "convId" to c.getString(0),
                    "role" to c.getString(1),
                    "content" to openText(c.getBlob(2)),
                    "created" to c.getLong(3),
                    "score" to score.toDouble(),
                )
            }
        }
    }

    private fun dot(a: FloatArray, b: FloatArray): Float {
        var s = 0f
        for (i in a.indices) s += a[i] * b[i]
        return s
    }

    /**
     * Fills the store with synthetic messages and random unit vectors and
     * times paging, title search and a full recall scan (Settings →
     * Performance). No model is needed.
     */
    fun selfTest(messages: Int): Map<String, Any?> {
        val conv = "selftest-" + System.nanoTime()
        val random = java.util.Random(7)
        val t0 = System.nanoTime()
        createConversation(conv, "Self test harbour lights", System.currentTimeMillis())
        writableDatabase.transaction {
            for (i in 0 until messages) {
                val id = (addMessage(conv, if (i % 2 == 0) "user" else "model",
                    "Message $i about lighthouses, tides and the harbour at dusk number ${i % 97}", emptyList(), null, i.toLong())["id"] as Long)
                val v = FloatArray(Embedder.DIMS) { random.nextGaussian().toFloat() }
                val n = Math.sqrt(v.sumOf { (it * it).toDouble() }).toFloat()
                for (k in v.indices) v[k] /= n
                insertOrThrow("vectors", null, ContentValues().apply {
                    put("msg_id", id)
                    put("conv_id", conv)
                    put("vec", packVector(v))
                })
            }
        }
        dropVectorCache()
        val insertMs = (System.nanoTime() - t0) / 1e6
        val t1 = System.nanoTime()
        messages(conv, Int.MAX_VALUE, 40)
        val pageMs = (System.nanoTime() - t1) / 1e6
        val t2 = System.nanoTime()
        search("harb", 20)
        val searchMs = (System.nanoTime() - t2) / 1e6
        val q = FloatArray(Embedder.DIMS) { if (it == 0) 1f else 0f }
        val t3 = System.nanoTime()
        rankAndLoad(q, null, 3, -1f)
        val recallMs = (System.nanoTime() - t3) / 1e6
        deleteConversation(conv)
        return mapOf("messages" to messages, "insertMs" to insertMs, "pageMs" to pageMs, "searchMs" to searchMs, "recallMs" to recallMs)
    }
}

private inline fun SQLiteDatabase.transaction(block: SQLiteDatabase.() -> Unit) {
    beginTransaction()
    try {
        block()
        setTransactionSuccessful()
    } finally {
        endTransaction()
    }
}

/** Title words for the search box: letters and digits, lower-cased. */
object TitleTerms {
    private val split = Regex("[^\\p{L}\\p{N}]+")

    fun words(text: String): List<String> =
        text.lowercase().split(split).filter { it.length >= 2 }

    /** Prefixes of 2..10 characters, so titles match while the user types. */
    fun prefixes(word: String): List<String> =
        (2..minOf(word.length, 10)).map { word.substring(0, it) }

    fun clipPrefix(word: String) = if (word.length > 10) word.substring(0, 10) else word
}
