package dev.abdullah.aithra

import android.app.ActivityManager
import android.app.ApplicationExitInfo
import android.content.Context
import android.os.Build
import java.io.File
import java.time.Instant

/**
 * The crash report shown on the next launch. Users have no USB cable or
 * logcat, so every crash this process can observe lands in one plain-text
 * file they can copy or share from the app: uncaught JVM exceptions, Dart
 * errors (sent over the channel), and native crashes and ANRs that Android
 * records after the process is gone.
 */
object CrashLog {
    /** A looping error must not fill the disk; the first entries are the useful ones. */
    private const val MAX_BYTES = 256 * 1024
    private const val ANR_TRACE_CHARS = 16 * 1024

    private fun file(context: Context) = File(context.filesDir, "last_crash.txt")
    private fun exitsSeen(context: Context) = File(context.filesDir, "exits_seen")

    fun install(context: Context) {
        // Android always installs its own handler (it kills the process and
        // shows the "app stopped" dialog); it must still run after ours.
        val previous = checkNotNull(Thread.getDefaultUncaughtExceptionHandler())
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            record(context, "Uncaught exception on thread ${thread.name}", error.stackTraceToString())
            previous.uncaughtException(thread, error)
        }
        recordProcessExits(context)
    }

    @Synchronized
    fun record(context: Context, title: String, detail: String) {
        val target = file(context)
        if (target.length() >= MAX_BYTES) return
        val entry = buildString {
            if (target.length() == 0L) appendLine(header(context)).appendLine()
            appendLine("== $title — ${Instant.now()}")
            appendLine(detail.trimEnd())
            appendLine()
        }
        target.appendText(entry)
    }

    fun read(context: Context): String? = file(context).takeIf { it.exists() }?.readText()

    @Synchronized
    fun clear(context: Context) {
        file(context).delete()
    }

    private fun header(context: Context): String {
        val pkg = context.packageManager.getPackageInfo(context.packageName, 0)
        return "Aithra ${pkg.versionName} (${pkg.longVersionCode})\n" +
            "${Build.MANUFACTURER} ${Build.MODEL} · Android ${Build.VERSION.RELEASE} (SDK ${Build.VERSION.SDK_INT})\n" +
            "ABI ${Build.SUPPORTED_ABIS.joinToString()}"
    }

    /**
     * Native crashes and ANRs kill the process before any Java code can run,
     * so they are read back from Android's exit history on the next start.
     */
    private fun recordProcessExits(context: Context) {
        val seenFile = exitsSeen(context)
        val seen = if (seenFile.exists()) seenFile.readText().toLong() else 0L
        val am = context.getSystemService(ActivityManager::class.java)
        val exits = am.getHistoricalProcessExitReasons(context.packageName, 0, 0)
            .filter { it.timestamp > seen }
        for (exit in exits.sortedBy { it.timestamp }) {
            when (exit.reason) {
                ApplicationExitInfo.REASON_CRASH_NATIVE ->
                    record(context, "Native crash at ${Instant.ofEpochMilli(exit.timestamp)}", describe(exit))
                ApplicationExitInfo.REASON_ANR -> {
                    val trace = exit.traceInputStream?.use { it.reader().readText().take(ANR_TRACE_CHARS) }
                    record(
                        context,
                        "Not responding (ANR) at ${Instant.ofEpochMilli(exit.timestamp)}",
                        listOfNotNull(describe(exit), trace).joinToString("\n\n"),
                    )
                }
            }
        }
        exits.maxOfOrNull { it.timestamp }?.let { seenFile.writeText(it.toString()) }
    }

    private fun describe(exit: ApplicationExitInfo) =
        "${exit.description ?: "no description"}\nstatus ${exit.status}, " +
            "importance ${exit.importance}, pss ${exit.pss} KB, rss ${exit.rss} KB"
}
