package dev.abdullah.aithra

import android.app.Application
import android.content.ComponentCallbacks2
import dev.abdullah.aithra.engine.Embedder
import dev.abdullah.aithra.engine.EngineCache
import dev.abdullah.aithra.engine.EngineHost
import io.flutter.embedding.engine.FlutterEngineGroup
import io.flutter.embedding.engine.FlutterEngineGroupCache
import java.io.File
import java.util.concurrent.Executors

/**
 * Owns everything that must exist once per process: the loaded model, the
 * chat database and the embedder. Android can destroy and recreate the
 * activity (opening the app from recents after it was finished) while the
 * process lives on; activity-owned copies would load a second model.
 */
class AithraApplication : Application() {
    val io = Executors.newSingleThreadExecutor { r -> Thread(r, "aithra-io") }
    val dbExec = Executors.newSingleThreadExecutor { r -> Thread(r, "aithra-db") }

    // Embedding runs off the db thread so chat-list and message reads never
    // wait behind it; SQLite (WAL) handles the two threads.
    val embedExec = Executors.newSingleThreadExecutor { r -> Thread(r, "aithra-embed") }

    lateinit var engineHost: EngineHost
        private set
    lateinit var db: ChatDb
        private set
    lateinit var embedder: Embedder
        private set

    /** Activities showing Flutter (the app, the Ask sheet). Main thread. */
    var surfaces = 0

    /**
     * The app and the Ask sheet run in engines of one group: a second
     * engine starts in a fraction of the time and memory of the first.
     * Created on first use, from an activity's onCreate, because creating
     * it finishes Flutter's initialization on the calling thread.
     */
    fun engineGroupId(): String {
        val cache = FlutterEngineGroupCache.getInstance()
        if (cache.get(ENGINE_GROUP) == null) cache.put(ENGINE_GROUP, FlutterEngineGroup(this))
        return ENGINE_GROUP
    }

    /**
     * Frees the models once the last Flutter activity has finished for
     * good: nothing will use them again in this process, and a reopened
     * app loads them afresh. A reply still generating under the foreground
     * service finishes first.
     */
    fun releaseIfNoSurface() {
        if (surfaces > 0) return
        engineHost.releaseWhenIdle()
        embedder.releaseNow()
    }

    private companion object {
        const val ENGINE_GROUP = "aithra"
    }

    override fun onCreate() {
        super.onCreate()
        CrashLog.install(this)
        engineHost = EngineHost(this)
        db = ChatDb(this)
        embedder = Embedder(embedExec)
        io.execute {
            sweepPartialImports()
            // Shared files wait in memory for the app (Inbox); a new process
            // has none waiting, so any copy left is from a process that died.
            Inbox.sharedDir(this).listFiles()!!.forEach { it.delete() }
            EngineCache.migrate(this)
        }
    }

    /** Frees the model's memory when Android asks; Dart reloads it on next use. */
    override fun onTrimMemory(level: Int) {
        super.onTrimMemory(level)
        if (level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND) {
            engineHost.release()
        }
    }

    /**
     * An import interrupted by the process dying leaves its partial copy;
     * no import can be running yet when the process starts. Unmounted
     * shared storage (null) has nothing to sweep.
     */
    private fun sweepPartialImports() {
        val models = File(getExternalFilesDir(null) ?: return, "models")
        models.walk().filter { it.isFile && it.name.endsWith(Media.PARTIAL_SUFFIX) }.forEach { it.delete() }
    }
}
