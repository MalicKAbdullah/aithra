package dev.abdullah.aithra.engine

import java.io.File

/**
 * Checks a file's magic bytes before an engine opens it. LiteRT-LM aborts
 * the whole process (a JNI error on its own error message) when handed a
 * file that is not a model, so anything else must never reach it.
 */
object ModelFormat {
    private val LITERTLM = "LITERTLM".toByteArray()
    private val GGUF = "GGUF".toByteArray()

    /** The runtime that reads [file], from its header; null when none does. */
    fun runtimeOf(file: File): String? {
        val head = ByteArray(LITERTLM.size)
        val n = file.inputStream().use { it.read(head) }
        return when {
            n >= LITERTLM.size && head.contentEquals(LITERTLM) -> "litertlm"
            n >= GGUF.size && head.copyOf(GGUF.size).contentEquals(GGUF) -> "llamacpp"
            else -> null
        }
    }

    fun require(file: File, runtime: String) {
        require(runtimeOf(file) == runtime) {
            "${file.name} is not a ${if (runtime == "llamacpp") "GGUF" else "LiteRT-LM"} model file"
        }
    }
}
