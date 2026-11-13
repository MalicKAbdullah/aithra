// JNI bridge between dev.abdullah.aithra.engine.LlamaNative and llama.cpp.
//
// One Session owns a model, a context and a sampler-free state; every
// generate() call clears the KV cache and prefills the whole conversation, so
// the Kotlin side never has to track positions.

#include <jni.h>
#include <android/log.h>

#include <chrono>
#include <cstring>
#include <string>
#include <vector>

#include "llama.h"

#define LOG_TAG "aithra_llama"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)

namespace {

struct Session {
    llama_model *model = nullptr;
    llama_context *ctx = nullptr;
    int n_ctx = 0;
    int n_batch = 0;
    bool template_thinks = false;
    std::string tmpl;
};

void throw_java(JNIEnv *env, const std::string &msg) {
    jclass cls = env->FindClass("java/lang/IllegalStateException");
    env->ThrowNew(cls, msg.c_str());
}

std::string to_string(JNIEnv *env, jstring s) {
    const char *chars = env->GetStringUTFChars(s, nullptr);
    std::string out(chars);
    env->ReleaseStringUTFChars(s, chars);
    return out;
}

// Java strings arrive as modified UTF-8 through GetStringUTFChars, which
// mangles characters outside the BMP; convert via getBytes("UTF-8") instead.
std::string to_utf8(JNIEnv *env, jstring s) {
    jclass str_cls = env->GetObjectClass(s);
    jmethodID get_bytes = env->GetMethodID(str_cls, "getBytes", "(Ljava/lang/String;)[B");
    jstring charset = env->NewStringUTF("UTF-8");
    auto bytes = (jbyteArray) env->CallObjectMethod(s, get_bytes, charset);
    jsize len = env->GetArrayLength(bytes);
    std::string out(len, '\0');
    env->GetByteArrayRegion(bytes, 0, len, reinterpret_cast<jbyte *>(&out[0]));
    env->DeleteLocalRef(bytes);
    env->DeleteLocalRef(charset);
    env->DeleteLocalRef(str_cls);
    return out;
}

std::vector<llama_token> tokenize(const llama_vocab *vocab, const std::string &text, bool add_special) {
    int n = -llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), nullptr, 0, add_special, true);
    std::vector<llama_token> tokens(n);
    int got = llama_tokenize(vocab, text.c_str(), (int32_t) text.size(), tokens.data(), n, add_special, true);
    tokens.resize(got < 0 ? 0 : got);
    return tokens;
}

std::string piece(const llama_vocab *vocab, llama_token token) {
    char buf[256];
    int n = llama_token_to_piece(vocab, token, buf, sizeof(buf), 0, false);
    if (n < 0) {
        std::string big(-n, '\0');
        llama_token_to_piece(vocab, token, &big[0], -n, 0, false);
        return big;
    }
    return std::string(buf, n);
}

// Length of the longest prefix of s that ends on a complete UTF-8 sequence.
size_t complete_utf8_prefix(const std::string &s) {
    size_t i = s.size();
    size_t back = 0;
    while (i > 0 && back < 4) {
        unsigned char c = s[i - 1];
        if ((c & 0xC0) != 0x80) {
            size_t need = (c & 0x80) == 0 ? 1 : (c & 0xE0) == 0xC0 ? 2 : (c & 0xF0) == 0xE0 ? 3 : 4;
            return (back + 1 >= need) ? s.size() : i - 1;
        }
        --i;
        ++back;
    }
    return s.size();
}

double ms_since(std::chrono::steady_clock::time_point t0) {
    return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count();
}

std::string format_chat(Session *s, JNIEnv *env, jobjectArray roles, jobjectArray contents) {
    jsize n = env->GetArrayLength(roles);
    std::vector<std::string> role_store(n), content_store(n);
    std::vector<llama_chat_message> msgs(n);
    for (jsize i = 0; i < n; ++i) {
        auto r = (jstring) env->GetObjectArrayElement(roles, i);
        auto c = (jstring) env->GetObjectArrayElement(contents, i);
        role_store[i] = to_string(env, r);
        content_store[i] = to_utf8(env, c);
        env->DeleteLocalRef(r);
        env->DeleteLocalRef(c);
    }
    for (jsize i = 0; i < n; ++i) msgs[i] = {role_store[i].c_str(), content_store[i].c_str()};

    const char *tmpl = s->tmpl.empty() ? nullptr : s->tmpl.c_str();
    std::vector<char> buf(8192);
    int len = llama_chat_apply_template(tmpl, msgs.data(), msgs.size(), true, buf.data(), (int32_t) buf.size());
    if (len < 0) return std::string();
    if (len > (int) buf.size()) {
        buf.resize(len);
        len = llama_chat_apply_template(tmpl, msgs.data(), msgs.size(), true, buf.data(), (int32_t) buf.size());
    }
    std::string prompt(buf.data(), len);
    // Thinking-capable templates (Qwen3 family) answer directly when the
    // assistant turn opens with an empty think block.
    if (s->template_thinks) prompt += "<think>\n\n</think>\n\n";
    return prompt;
}

}  // namespace

extern "C" JNIEXPORT void JNICALL
Java_dev_abdullah_aithra_engine_LlamaNative_nativeInit(JNIEnv *, jobject) {
    llama_backend_init();
}

extern "C" JNIEXPORT jstring JNICALL
Java_dev_abdullah_aithra_engine_LlamaNative_nativeSystemInfo(JNIEnv *env, jobject) {
    return env->NewStringUTF(llama_print_system_info());
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_abdullah_aithra_engine_LlamaNative_nativeLoad(JNIEnv *env, jobject, jstring jpath, jint threads, jint n_ctx) {
    std::string path = to_string(env, jpath);
    llama_model_params mp = llama_model_default_params();
    llama_model *model = llama_model_load_from_file(path.c_str(), mp);
    if (!model) {
        throw_java(env, "llama.cpp could not load " + path);
        return 0;
    }
    llama_context_params cp = llama_context_default_params();
    cp.n_ctx = n_ctx;
    cp.n_batch = 512;
    cp.n_ubatch = 512;
    cp.n_threads = threads;
    cp.n_threads_batch = threads;
    llama_context *ctx = llama_init_from_model(model, cp);
    if (!ctx) {
        llama_model_free(model);
        throw_java(env, "llama.cpp could not create a context");
        return 0;
    }
    auto *s = new Session();
    s->model = model;
    s->ctx = ctx;
    s->n_ctx = n_ctx;
    s->n_batch = 512;
    const char *t = llama_model_chat_template(model, nullptr);
    s->tmpl = t ? t : "";
    s->template_thinks = s->tmpl.find("<think>") != std::string::npos;
    LOGI("loaded %s threads=%d n_ctx=%d", path.c_str(), threads, n_ctx);
    return reinterpret_cast<jlong>(s);
}

extern "C" JNIEXPORT void JNICALL
Java_dev_abdullah_aithra_engine_LlamaNative_nativeFree(JNIEnv *, jobject, jlong handle) {
    auto *s = reinterpret_cast<Session *>(handle);
    llama_free(s->ctx);
    llama_model_free(s->model);
    delete s;
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_abdullah_aithra_engine_LlamaNative_nativeContextSize(JNIEnv *, jobject, jlong handle) {
    return reinterpret_cast<Session *>(handle)->n_ctx;
}

extern "C" JNIEXPORT jint JNICALL
Java_dev_abdullah_aithra_engine_LlamaNative_nativeCountTokens(JNIEnv *env, jobject, jlong handle, jstring text) {
    auto *s = reinterpret_cast<Session *>(handle);
    return (jint) tokenize(llama_model_get_vocab(s->model), to_utf8(env, text), false).size();
}

// Returns [promptTokens, prefillMs, ttftMs, decodeTokens, decodeMs].
extern "C" JNIEXPORT jdoubleArray JNICALL
Java_dev_abdullah_aithra_engine_LlamaNative_nativeGenerate(
        JNIEnv *env, jobject, jlong handle, jobjectArray roles, jobjectArray contents,
        jint max_tokens, jboolean ignore_eos, jfloat temperature, jobject callback) {
    auto *s = reinterpret_cast<Session *>(handle);
    const llama_vocab *vocab = llama_model_get_vocab(s->model);

    std::string prompt = format_chat(s, env, roles, contents);
    if (prompt.empty()) {
        throw_java(env, "This model's chat template is not supported by llama.cpp");
        return nullptr;
    }
    std::vector<llama_token> tokens = tokenize(vocab, prompt, true);
    if ((int) tokens.size() + max_tokens > s->n_ctx) {
        throw_java(env, "Prompt of " + std::to_string(tokens.size()) + " tokens does not fit the " +
                        std::to_string(s->n_ctx) + "-token context");
        return nullptr;
    }

    jclass cb_cls = env->GetObjectClass(callback);
    jmethodID on_token = env->GetMethodID(cb_cls, "onToken", "([B)Z");

    llama_sampler *smpl = llama_sampler_chain_init(llama_sampler_chain_default_params());
    if (temperature <= 0.0f) {
        llama_sampler_chain_add(smpl, llama_sampler_init_greedy());
    } else {
        llama_sampler_chain_add(smpl, llama_sampler_init_top_k(40));
        llama_sampler_chain_add(smpl, llama_sampler_init_top_p(0.95f, 1));
        llama_sampler_chain_add(smpl, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(smpl, llama_sampler_init_dist(LLAMA_DEFAULT_SEED));
    }

    llama_memory_clear(llama_get_memory(s->ctx), true);
    auto t0 = std::chrono::steady_clock::now();

    for (size_t i = 0; i < tokens.size(); i += s->n_batch) {
        int n = (int) std::min((size_t) s->n_batch, tokens.size() - i);
        if (llama_decode(s->ctx, llama_batch_get_one(tokens.data() + i, n)) != 0) {
            llama_sampler_free(smpl);
            throw_java(env, "llama_decode failed during prefill");
            return nullptr;
        }
    }
    double prefill_ms = ms_since(t0);
    double ttft_ms = 0;
    int decoded = 0;
    auto t_decode = std::chrono::steady_clock::now();
    std::string pending;
    bool stop = false;

    while (decoded < max_tokens && !stop) {
        llama_token tok = llama_sampler_sample(smpl, s->ctx, -1);
        if (decoded == 0) {
            ttft_ms = ms_since(t0);
            t_decode = std::chrono::steady_clock::now();
        }
        bool eog = llama_vocab_is_eog(vocab, tok);
        if (eog && !ignore_eos) break;
        if (!eog) {
            pending += piece(vocab, tok);
            size_t ready = complete_utf8_prefix(pending);
            if (ready > 0) {
                jbyteArray arr = env->NewByteArray((jsize) ready);
                env->SetByteArrayRegion(arr, 0, (jsize) ready, reinterpret_cast<const jbyte *>(pending.data()));
                jboolean keep = env->CallBooleanMethod(callback, on_token, arr);
                env->DeleteLocalRef(arr);
                pending.erase(0, ready);
                if (!keep) stop = true;
            }
        }
        if (llama_decode(s->ctx, llama_batch_get_one(&tok, 1)) != 0) break;
        ++decoded;
    }
    double decode_ms = ms_since(t_decode);
    llama_sampler_free(smpl);

    double out[5] = {(double) tokens.size(), prefill_ms, ttft_ms, (double) decoded, decode_ms};
    jdoubleArray result = env->NewDoubleArray(5);
    env->SetDoubleArrayRegion(result, 0, 5, out);
    return result;
}
