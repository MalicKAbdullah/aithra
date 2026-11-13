package dev.abdullah.aithra

import android.content.ContentValues
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.database.sqlite.SQLiteOpenHelper
import java.nio.ByteBuffer
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec
import kotlin.math.ln

/**
 * Encrypted chat store on Android's built-in SQLite.
 *
 * Every text column (titles, messages, summaries, drafts) and every image is
 * AES-256-GCM encrypted with the app's data key, in core_crypto's
 * `EncryptedPayload` layout (salt 32 | nonce 12 | ciphertext+tag), so Dart can
 * decrypt the same bytes. The key lives in core_storage (Android Keystore
 * backed) and is handed over by Dart on [open]; it is never written here.
 *
 * Search and cross-chat recall use a blind keyword index: each word is stored
 * only as a keyed HMAC, so the index answers "which messages contain this
 * word" without holding any plaintext.
 */
class ChatDb(context: Context) : SQLiteOpenHelper(context, "aithra.db", null, 1) {
    private companion object {
        /** Enough for two lines of preview after Markdown is stripped. */
        const val PREVIEW_CHARS = 240
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
                created INTEGER NOT NULL, stats TEXT, length INTEGER NOT NULL DEFAULT 0)""",
        )
        db.execSQL("CREATE UNIQUE INDEX messages_conv_seq ON messages(conv_id, seq)")
        db.execSQL("CREATE TABLE media(id TEXT PRIMARY KEY, data BLOB NOT NULL, thumb BLOB NOT NULL)")
        // kind 0: a word of a message; kind 1: a word prefix of a title.
        db.execSQL("CREATE TABLE terms(hash INTEGER NOT NULL, kind INTEGER NOT NULL, msg_id INTEGER NOT NULL, conv_id TEXT NOT NULL, tf INTEGER NOT NULL)")
        db.execSQL("CREATE INDEX terms_hash ON terms(hash, kind)")
        db.execSQL("CREATE INDEX terms_conv ON terms(conv_id)")
    }

    override fun onUpgrade(db: SQLiteDatabase, oldVersion: Int, newVersion: Int) {}

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

    private fun indexMessage(db: SQLiteDatabase, msgId: Long, convId: String, text: String): Int {
        val words = Terms.words(text)
        val counts = words.groupingBy { it }.eachCount()
        val stmt = db.compileStatement("INSERT INTO terms(hash, kind, msg_id, conv_id, tf) VALUES(?,0,?,?,?)")
        for ((term, tf) in counts) {
            stmt.bindLong(1, termHash(term))
            stmt.bindLong(2, msgId)
            stmt.bindString(3, convId)
            stmt.bindLong(4, tf.toLong())
            stmt.executeInsert()
        }
        return words.size
    }

    private fun indexTitle(db: SQLiteDatabase, convId: String, title: String) {
        db.delete("terms", "conv_id = ? AND kind = 1", arrayOf(convId))
        val stmt = db.compileStatement("INSERT INTO terms(hash, kind, msg_id, conv_id, tf) VALUES(?,1,0,?,1)")
        for (prefix in Terms.words(title).flatMap(Terms::prefixes).toSet()) {
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
            delete("terms", "conv_id = ?", arrayOf(id))
            delete("messages", "conv_id = ?", arrayOf(id))
            delete("conversations", "id = ?", arrayOf(id))
        }
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
    )

    /** The newest [limit] messages with seq < [beforeSeq], newest first. */
    fun messages(convId: String, beforeSeq: Int, limit: Int): List<Map<String, Any?>> =
        readableDatabase.rawQuery(
            "SELECT id, seq, role, content, images, created, stats FROM messages WHERE conv_id = ? AND seq < ? ORDER BY seq DESC LIMIT ?",
            arrayOf(convId, beforeSeq.toString(), limit.toString()),
        ).use { c -> buildList { while (c.moveToNext()) add(messageRow(c)) } }

    /** Messages with seq in [fromSeq, toSeq), oldest first. */
    fun messageRange(convId: String, fromSeq: Int, toSeq: Int): List<Map<String, Any?>> =
        readableDatabase.rawQuery(
            "SELECT id, seq, role, content, images, created, stats FROM messages WHERE conv_id = ? AND seq >= ? AND seq < ? ORDER BY seq ASC",
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
            val length = indexMessage(this, id, convId, content)
            execSQL("UPDATE messages SET length = ? WHERE id = ?", arrayOf<Any>(length, id))
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
            val convId = rawQuery("SELECT conv_id FROM messages WHERE id = ?", arrayOf(id.toString()))
                .use { c -> c.moveToFirst(); c.getString(0) }
            delete("terms", "msg_id = ? AND kind = 0", arrayOf(id.toString()))
            val length = indexMessage(this, id, convId, content)
            update("messages", ContentValues().apply {
                put("content", sealText(content))
                put("stats", stats)
                put("length", length)
            }, "id = ?", arrayOf(id.toString()))
        }
    }

    /** Deletes every message with seq >= [fromSeq] (edit and regenerate). */
    fun truncate(convId: String, fromSeq: Int) {
        writableDatabase.transaction {
            val ids = rawQuery("SELECT id, images FROM messages WHERE conv_id = ? AND seq >= ?", arrayOf(convId, fromSeq.toString()))
                .use { c -> buildList { while (c.moveToNext()) add(c.getLong(0) to c.getString(1)) } }
            for ((id, images) in ids) {
                delete("terms", "msg_id = ? AND kind = 0", arrayOf(id.toString()))
                images.split(',').filter { it.isNotEmpty() }.forEach { delete("media", "id = ?", arrayOf(it)) }
            }
            delete("messages", "conv_id = ? AND seq >= ?", arrayOf(convId, fromSeq.toString()))
            execSQL(
                "UPDATE conversations SET message_count = (SELECT COUNT(*) FROM messages WHERE conv_id = ?), summarized_upto = MIN(summarized_upto, ?) WHERE id = ?",
                arrayOf<Any>(convId, fromSeq, convId),
            )
        }
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

    /**
     * Conversation ids matching every word of [query]: whole words in
     * messages, or word prefixes in titles.
     */
    fun search(query: String, limit: Int): List<Map<String, Any?>> {
        val words = Terms.words(query).distinct()
        if (words.isEmpty()) return emptyList()
        val db = readableDatabase
        var matches: Set<String>? = null
        for (w in words) {
            val ids = db.rawQuery(
                "SELECT DISTINCT conv_id FROM terms WHERE (hash = ? AND kind = 0) OR (hash = ? AND kind = 1)",
                arrayOf(termHash(w).toString(), termHash(Terms.clipPrefix(w)).toString()),
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

    /**
     * Past messages from other conversations most relevant to [query], ranked
     * with BM25 over the blind index.
     */
    fun recall(query: String, excludeConv: String?, limit: Int): List<Map<String, Any?>> {
        val words = Terms.words(query).distinct()
        if (words.isEmpty()) return emptyList()
        val db = readableDatabase
        val (n, avgLen) = db.rawQuery("SELECT COUNT(*), AVG(length) FROM messages", null)
            .use { c -> c.moveToFirst(); c.getLong(0) to c.getDouble(1) }
        if (n == 0L) return emptyList()
        val scores = HashMap<Long, Double>()
        val lengths = HashMap<Long, Int>()
        for (w in words) {
            val hash = termHash(w).toString()
            val df = db.rawQuery("SELECT COUNT(*) FROM terms WHERE hash = ? AND kind = 0", arrayOf(hash))
                .use { c -> c.moveToFirst(); c.getLong(0) }
            if (df == 0L) continue
            val idf = ln(1.0 + (n - df + 0.5) / (df + 0.5))
            db.rawQuery(
                "SELECT t.msg_id, t.tf, m.length FROM terms t JOIN messages m ON m.id = t.msg_id " +
                    "WHERE t.hash = ? AND t.kind = 0 AND t.conv_id != ?",
                arrayOf(hash, excludeConv ?: ""),
            ).use { c ->
                while (c.moveToNext()) {
                    val id = c.getLong(0)
                    val tf = c.getInt(1).toDouble()
                    val len = c.getInt(2)
                    lengths[id] = len
                    val norm = tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * len / maxOf(avgLen, 1.0)))
                    scores[id] = (scores[id] ?: 0.0) + idf * norm
                }
            }
        }
        val top = scores.entries.sortedByDescending { it.value }.take(limit)
        return top.mapNotNull { (id, score) ->
            db.rawQuery(
                "SELECT m.conv_id, m.role, m.content, m.created FROM messages m WHERE m.id = ?",
                arrayOf(id.toString()),
            ).use { c ->
                if (!c.moveToFirst()) null else mapOf(
                    "convId" to c.getString(0),
                    "role" to c.getString(1),
                    "content" to openText(c.getBlob(2)),
                    "created" to c.getLong(3),
                    "score" to score,
                )
            }
        }
    }

    /** Fills the store with synthetic messages and times typical queries (Settings → Performance). */
    fun selfTest(messages: Int): Map<String, Any?> {
        val conv = "selftest-" + System.nanoTime()
        val t0 = System.nanoTime()
        createConversation(conv, "Self test", System.currentTimeMillis())
        writableDatabase.transaction {
            for (i in 0 until messages) {
                addMessage(conv, if (i % 2 == 0) "user" else "model",
                    "Message $i about lighthouses, tides and the harbour at dusk number ${i % 97}", emptyList(), null, i.toLong())
            }
        }
        val insertMs = (System.nanoTime() - t0) / 1e6
        val t1 = System.nanoTime()
        messages(conv, Int.MAX_VALUE, 40)
        val pageMs = (System.nanoTime() - t1) / 1e6
        val t2 = System.nanoTime()
        search("harbour", 20)
        val searchMs = (System.nanoTime() - t2) / 1e6
        val t3 = System.nanoTime()
        recall("tides at dusk", null, 3)
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

object Terms {
    private val stop = setOf(
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "can", "do", "for", "from", "has",
        "have", "how", "i", "if", "in", "is", "it", "its", "me", "my", "of", "on", "or", "so",
        "that", "the", "this", "to", "was", "we", "what", "when", "which", "who", "why", "will",
        "with", "you", "your",
    )
    private val split = Regex("[^\\p{L}\\p{N}]+")

    fun words(text: String): List<String> =
        text.lowercase().split(split).filter { it.length >= 2 && it !in stop }

    /** Prefixes of 2..10 characters, so titles match while the user types. */
    fun prefixes(word: String): List<String> =
        (2..minOf(word.length, 10)).map { word.substring(0, it) }

    fun clipPrefix(word: String) = if (word.length > 10) word.substring(0, 10) else word
}
