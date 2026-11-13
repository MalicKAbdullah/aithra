package dev.abdullah.aithra.engine

object CpuFeatures {
    init {
        System.loadLibrary("aithra_cpu")
    }

    /**
     * Whether this CPU has the instructions aithra_llama is compiled for
     * (dotprod, i8mm, fp16). Without them the GGUF runtime and embeddings
     * are unavailable, because loading ggml would end in SIGILL.
     */
    val runsLlama: Boolean by lazy { nativeRunsLlama() }

    private external fun nativeRunsLlama(): Boolean
}
