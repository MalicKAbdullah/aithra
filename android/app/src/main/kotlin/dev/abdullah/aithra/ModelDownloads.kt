package dev.abdullah.aithra

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.IBinder
import android.os.StatFs
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.Executors

/**
 * Model downloads the app runs itself, so a dropped connection resumes from
 * the bytes already on disk (HTTP Range) instead of starting over. Bytes go
 * to `<name>.part` beside the model; the finished file is checked against
 * its SHA-256 and only then takes its real name. Download records survive
 * the process in `downloads.json`; [resume] continues unfinished ones.
 *
 * Records are reported with Android DownloadManager's status and reason
 * codes, which the Dart side already understands.
 */
object ModelDownloads {
    const val PENDING = 1
    const val RUNNING = 2
    const val PAUSED = 4
    const val SUCCESSFUL = 8
    const val FAILED = 16

    // Reasons, as DownloadManager.PAUSED_* / ERROR_* (and one of ours).
    const val PAUSED_RETRYING = 1
    const val PAUSED_NO_NETWORK = 2
    const val ERROR_FILE = 1001
    const val ERROR_SPACE = 1006
    const val ERROR_CORRUPT = 2001

    const val PART_SUFFIX = ".part"
    private const val MAX_BACKOFF_MS = 60_000L

    private class Record(
        val id: Long,
        val url: String,
        val fileName: String,
        val title: String,
        val size: Long,
        val sha256: String,
        @Volatile var status: Int,
        @Volatile var reason: Int = 0,
        @Volatile var cancelled: Boolean = false,
    ) {
        /** A worker owns this record; guarded by [ModelDownloads]. */
        var active = false
    }

    private val records = LinkedHashMap<Long, Record>()
    private val workers = Executors.newCachedThreadPool { r -> Thread(r, "aithra-download") }
    private var loaded = false

    private fun stateFile(context: Context) = File(context.filesDir, "downloads.json")
    private fun target(context: Context, r: Record) = File(modelsDir(context), r.fileName)
    private fun part(context: Context, r: Record) = File(modelsDir(context), r.fileName + PART_SUFFIX)

    /**
     * Starts downloading [fileName], or returns the download already running
     * for it, so a second tap cannot start a second copy.
     */
    @Synchronized
    fun start(context: Context, url: String, fileName: String, title: String, size: Long, sha256: String): Long {
        load(context)
        records.values.firstOrNull { it.fileName == fileName && it.status in listOf(PENDING, RUNNING, PAUSED) }
            ?.let { return it.id }
        records.values.removeAll { it.fileName == fileName }
        val record = Record(System.currentTimeMillis(), url, fileName, title, size, sha256, PENDING)
        val onDisk = part(context, record).length()
        val free = StatFs(modelsDir(context).path).availableBytes
        check(free >= size - onDisk) {
            "Not enough free space: the download needs ${(size - onDisk) shr 20} MB and ${free shr 20} MB is free"
        }
        records[record.id] = record
        save(context)
        run(context, record)
        return record.id
    }

    /** Continues downloads the process was killed during. Call from the foreground. */
    @Synchronized
    fun resume(context: Context) {
        load(context)
        records.values.filter { it.status in listOf(PENDING, RUNNING, PAUSED) }.forEach { run(context, it) }
    }

    @Synchronized
    fun query(context: Context): List<Map<String, Any?>> {
        load(context)
        return records.values.map { r ->
            val done = if (r.status == SUCCESSFUL) target(context, r).length() else part(context, r).length()
            mapOf(
                "id" to r.id,
                "fileName" to r.fileName,
                "status" to r.status,
                "reason" to r.reason,
                "downloaded" to done,
                "total" to r.size,
            )
        }
    }

    /** Cancels a download and deletes its partial file, or forgets a finished one. */
    @Synchronized
    fun remove(context: Context, id: Long) {
        load(context)
        val r = records.remove(id) ?: return
        r.cancelled = true
        if (r.status != SUCCESSFUL) part(context, r).delete()
        save(context)
    }

    private fun run(context: Context, r: Record) {
        if (r.active) return
        r.active = true
        DownloadService.hold(context)
        workers.execute {
            try {
                download(context, r)
            } finally {
                DownloadService.release(context)
                synchronized(this) {
                    r.active = false
                    save(context)
                }
            }
        }
    }

    private fun download(context: Context, r: Record) {
        var backoff = 2_000L
        while (!r.cancelled) {
            try {
                r.status = RUNNING
                r.reason = 0
                fetch(context, r)
                if (r.cancelled) return
                if (!sha256(part(context, r)).equals(r.sha256, ignoreCase = true)) {
                    part(context, r).delete()
                    fail(r, ERROR_CORRUPT)
                    return
                }
                if (part(context, r).renameTo(target(context, r))) r.status = SUCCESSFUL else fail(r, ERROR_FILE)
                return
            } catch (e: HttpStatus) {
                // 4xx will not change by retrying; 5xx and 429 might.
                if (e.code in 400..499 && e.code != 429) {
                    fail(r, e.code)
                    return
                }
            } catch (e: IllegalStateException) {
                // modelsDir: shared storage was unmounted mid-download.
                fail(r, ERROR_FILE)
                return
            } catch (e: IOException) {
                if (StatFs(modelsDir(context).path).availableBytes < r.size - part(context, r).length()) {
                    fail(r, ERROR_SPACE)
                    return
                }
            }
            if (r.cancelled) return
            r.status = PAUSED
            r.reason = if (online(context)) PAUSED_RETRYING else PAUSED_NO_NETWORK
            synchronized(this) { save(context) }
            Thread.sleep(backoff)
            backoff = minOf(backoff * 2, MAX_BACKOFF_MS)
            while (!online(context) && !r.cancelled) Thread.sleep(2_000L)
        }
    }

    private fun fail(r: Record, reason: Int) {
        r.status = FAILED
        r.reason = reason
    }

    private class HttpStatus(val code: Int) : IOException("HTTP $code")

    /** Appends the rest of the file to the part file; returns when it is complete. */
    private fun fetch(context: Context, r: Record) {
        val part = part(context, r)
        var have = part.length()
        if (have == r.size) return
        if (have > r.size) {
            part.delete()
            have = 0
        }
        val conn = URL(r.url).openConnection() as HttpURLConnection
        conn.connectTimeout = 20_000
        conn.readTimeout = 30_000
        if (have > 0) conn.setRequestProperty("Range", "bytes=$have-")
        try {
            val code = conn.responseCode
            val append = when (code) {
                HttpURLConnection.HTTP_PARTIAL -> true
                // The server ignored the range: the body is the whole file.
                HttpURLConnection.HTTP_OK -> false
                else -> throw HttpStatus(code)
            }
            conn.inputStream.use { input ->
                FileOutputStream(part, append).use { output ->
                    val buf = ByteArray(1 shl 16)
                    while (!r.cancelled) {
                        val n = input.read(buf)
                        if (n < 0) break
                        output.write(buf, 0, n)
                    }
                }
            }
        } finally {
            conn.disconnect()
        }
        if (!r.cancelled && part.length() != r.size) throw IOException("connection closed early")
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buf = ByteArray(1 shl 20)
            while (true) {
                val n = input.read(buf)
                if (n < 0) break
                digest.update(buf, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    /**
     * A network that claims internet access. Not VALIDATED: networks where
     * Android's connectivity check is blocked never validate, yet download.
     */
    private fun online(context: Context): Boolean {
        val cm = context.getSystemService(ConnectivityManager::class.java)
        val caps = cm.getNetworkCapabilities(cm.activeNetwork) ?: return false
        return caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
    }

    private fun load(context: Context) {
        if (loaded) return
        loaded = true
        val file = stateFile(context)
        if (!file.exists()) return
        val array = JSONArray(file.readText())
        for (i in 0 until array.length()) {
            val o = array.getJSONObject(i)
            val r = Record(
                id = o.getLong("id"),
                url = o.getString("url"),
                fileName = o.getString("fileName"),
                title = o.getString("title"),
                size = o.getLong("size"),
                sha256 = o.getString("sha256"),
                status = o.getInt("status"),
                reason = o.getInt("reason"),
            )
            records[r.id] = r
        }
    }

    private fun save(context: Context) {
        val array = JSONArray()
        for (r in records.values) {
            array.put(
                JSONObject()
                    .put("id", r.id)
                    .put("url", r.url)
                    .put("fileName", r.fileName)
                    .put("title", r.title)
                    .put("size", r.size)
                    .put("sha256", r.sha256)
                    .put("status", r.status)
                    .put("reason", r.reason),
            )
        }
        val tmp = File(stateFile(context).path + ".tmp")
        tmp.writeText(array.toString())
        tmp.renameTo(stateFile(context))
    }
}

/** Keeps the process alive, with a notification, while any download runs. */
class DownloadService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(CHANNEL, "Model downloads", NotificationManager.IMPORTANCE_LOW),
        )
        val notification = Notification.Builder(this, CHANNEL)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle("Downloading a model")
            .setContentText("Continues when the connection drops")
            .setOngoing(true)
            .build()
        startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        onForeground(this)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        onStopped()
        super.onDestroy()
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android 15 caps data-sync services at six hours a day; downloads
        // pause and resume the next time the app opens.
        stopSelf()
    }

    companion object {
        private const val CHANNEL = "downloads"
        private const val ID = 2
        private var holders = 0

        // Stopping a service that has not yet called startForeground kills
        // the app on some Android versions, so a release that comes first
        // leaves the stop to [onForeground].
        private var foreground = false

        @Synchronized
        fun hold(context: Context) {
            if (holders++ == 0 && !foreground) {
                context.startForegroundService(Intent(context, DownloadService::class.java))
            }
        }

        @Synchronized
        fun release(context: Context) {
            if (--holders == 0 && foreground) context.stopService(Intent(context, DownloadService::class.java))
        }

        @Synchronized
        private fun onForeground(service: Service) {
            foreground = true
            if (holders == 0) service.stopSelf()
        }

        @Synchronized
        private fun onStopped() {
            foreground = false
        }
    }
}
