// CPU feature probe, kept in its own library: aithra_llama links ggml built
// for armv8.2-a+dotprod+i8mm+fp16, and phones without those instructions
// (Tensor G1/G2, for example) die with SIGILL as soon as ggml runs.

#include <jni.h>

#if defined(__aarch64__)
#include <asm/hwcap.h>
#include <sys/auxv.h>
#endif

extern "C" JNIEXPORT jboolean JNICALL
Java_dev_abdullah_aithra_engine_CpuFeatures_nativeRunsLlama(JNIEnv *, jobject) {
#if defined(__aarch64__)
    const unsigned long hwcap = getauxval(AT_HWCAP);
    const unsigned long hwcap2 = getauxval(AT_HWCAP2);
    return (hwcap & HWCAP_ASIMDDP) && (hwcap & HWCAP_FPHP) && (hwcap & HWCAP_ASIMDHP) &&
           (hwcap2 & HWCAP2_I8MM);
#else
    // ggml is built with Arm-only flags; other ABIs exist only for the
    // emulator launch tests.
    return JNI_FALSE;
#endif
}
