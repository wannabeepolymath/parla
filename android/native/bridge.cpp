#include <jni.h>
#include <whisper.h>
#include <ggml-backend.h>
#include "bridge_policy.h"
#include <atomic>
#include <algorithm>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>
#include <cstdint>
#include <thread>
#include <stdexcept>

namespace {
struct Token { std::atomic<bool> canceled{false}; };
std::mutex registryMutex, inferenceMutex;
std::unordered_map<jlong, std::shared_ptr<Token>> tokens;
jlong nextID = 1;
std::string lastLanguage = "en", lastModel;
std::shared_ptr<Token> lookup(jlong id) {
    std::lock_guard<std::mutex> lock(registryMutex);
    auto i = tokens.find(id); return i == tokens.end() ? nullptr : i->second;
}
void failure(JNIEnv *env, const char *message) noexcept {
    if (env->ExceptionCheck()) return;
    auto cls = env->FindClass("java/lang/IllegalStateException");
    if (cls) env->ThrowNew(cls, message);
}
std::string bytes(JNIEnv *env, jbyteArray a, size_t limit) {
    if (!a) throw std::runtime_error("Missing UTF-8 bytes");
    auto n = env->GetArrayLength(a);
    if (n < 0 || size_t(n) > limit) throw std::runtime_error("Oversized UTF-8 input");
    std::string s(n, '\0');
    env->GetByteArrayRegion(a, 0, n, reinterpret_cast<jbyte *>(s.data()));
    if (env->ExceptionCheck() || s.find('\0') != std::string::npos) throw std::runtime_error("Invalid UTF-8 input");
    return s;
}
bool aborted(void *data) { return static_cast<Token *>(data)->canceled.load(std::memory_order_relaxed); }
// CPU only; flash attention is whisper's own default and the faster CPU encoder.
whisper_context *load(const std::string &model) {
#ifdef PARLA_CPU_VARIANTS
    // arm64 ships every ggml Android CPU variant. Best first: ggml refuses (score 0) one this CPU can't run,
    // so fp16/dotprod phones get those kernels and armv8.0 phones still get the baseline.
    static const bool cpu = [] {
        for (const char *v : {"android_armv9.2_2", "android_armv9.2_1", "android_armv9.0_1", "android_armv8.6_1",
                              "android_armv8.2_2", "android_armv8.2_1", "android_armv8.0_1"})
            if (ggml_backend_load((std::string("libggml-cpu-") + v + ".so").c_str())) return true;
        return false;
    }();
    if (!cpu) throw std::runtime_error("On-device speech isn't available on this processor.");
#endif
    auto cp = whisper_context_default_params(); cp.use_gpu = false; cp.flash_attn = true;
    return whisper_init_from_file_with_params(model.c_str(), cp);
}
}
extern "C" JNIEXPORT jlong JNICALL Java_dev_parla_android_WhisperJni_createToken(JNIEnv *env, jobject) {
    try { std::lock_guard<std::mutex> lock(registryMutex); const auto id = nextID++; tokens.emplace(id, std::make_shared<Token>()); return id; }
    catch (...) { failure(env, "Could not allocate recognition token"); return 0; }
}
extern "C" JNIEXPORT void JNICALL Java_dev_parla_android_WhisperJni_cancel(JNIEnv *env, jobject, jlong id) {
    try { auto token = lookup(id); if (token) token->canceled.store(true, std::memory_order_relaxed); }
    catch (...) { failure(env, "Could not cancel recognition"); }
}
extern "C" JNIEXPORT void JNICALL Java_dev_parla_android_WhisperJni_release(JNIEnv *env, jobject, jlong id) {
    try { std::lock_guard<std::mutex> lock(registryMutex); tokens.erase(id); }
    catch (...) { failure(env, "Could not release recognition token"); }
}
namespace {
void put(std::string &out, uint64_t value, int bytes) { for (int i = 0; i < bytes; ++i) out.push_back(char((value >> (8 * i)) & 0xff)); }
// Timed payload (little-endian): u32 count, then per segment i64 t0, i64 t1, u32 length, raw UTF-8 bytes.
// Mac copyTimedResult bounds: at most 10000 segments and 1 MiB of text; each C string is scanned within the budget.
std::string timedPayload(whisper_context *ctx) {
    const int count = whisper_full_n_segments(ctx);
    if (count < 0 || count > 10000) throw std::runtime_error("The timed transcript is too large.");
    std::string out; put(out, uint64_t(count), 4);
    size_t total = 0;
    for (int i = 0; i < count; ++i) {
        const char *text = whisper_full_get_segment_text(ctx, i);
        if (!text) throw std::runtime_error("On-device transcription failed");
        const size_t remaining = 1048576 - total;
        size_t length = 0;
        while (length <= remaining && text[length] != 0) ++length;
        if (length > remaining) throw std::runtime_error("The timed transcript is too large.");
        total += length;
        put(out, uint64_t(whisper_full_get_segment_t0(ctx, i)), 8);
        put(out, uint64_t(whisper_full_get_segment_t1(ctx, i)), 8);
        put(out, uint64_t(length), 4);
        out.append(text, length);
    }
    return out;
}
jbyteArray recognize(JNIEnv *env, jlong id, jbyteArray modelBytes, jfloatArray sampleArray, jbyteArray promptBytes, jbyteArray languageBytes, bool timed) {
    try {
        auto token = lookup(id);
        if (!token) throw std::runtime_error("Unknown recognition token");
        // Native init, decode and free are one serial lifecycle. Cancellation never takes this lock.
        std::lock_guard<std::mutex> lock(inferenceMutex);
        if (token->canceled.load()) return nullptr;
        const auto model = bytes(env, modelBytes, 8192);
        if (model != lastModel) { lastLanguage = "en"; lastModel = model; }
        const auto terms = bytes(env, promptBytes, 2048);
        const auto chosen = bytes(env, languageBytes, 32);
        if (!sampleArray) throw std::runtime_error("No samples");
        const auto count = env->GetArrayLength(sampleArray);
        if (count < 6400 || count > 16000 * 600) throw std::runtime_error("Invalid sample count");
        std::vector<float> samples(count);
        env->GetFloatArrayRegion(sampleArray, 0, count, samples.data());
        if (env->ExceptionCheck()) return nullptr;
        std::unique_ptr<whisper_context, decltype(&whisper_free)> ctx(load(model), whisper_free);
        if (!ctx) throw std::runtime_error("Model could not be loaded. Verify the model or choose a smaller one.");
        // Init cannot abort; token still invalidates delivery immediately and owns state until return.
        if (token->canceled.load()) return nullptr;
        const bool multi = whisper_is_multilingual(ctx.get());
        // The global registry has 100 ids; a 51865-vocabulary model has 99 (id 99 is its translate token).
        const int languages = parla::language_count(whisper_token_sot(ctx.get()), whisper_token_translate(ctx.get()));
        const int pinnedId = chosen == "auto" ? -1 : whisper_lang_id(chosen.c_str());
        const bool pinned = pinnedId >= 0 && pinnedId < languages;
        if (timed) {
            // Mac decodeTimed's exact pinned-implementation predicate, and a chosen language (one decode, no re-detection).
            if (whisper_model_n_text_layer(ctx.get()) == 2 && whisper_model_n_vocab(ctx.get()) != 51866) throw std::runtime_error("Timestamps aren't available for this speech model.");
            if (multi && !pinned) throw std::runtime_error("Choose a language to transcribe with timestamps.");
        }
        std::string language = !multi ? "en" : pinned ? chosen : lastLanguage;
        // whisper keeps only the last n_text_ctx/2 - 1 prompt tokens; select whole terms in priority order.
        const int capacity = std::max(0, whisper_n_text_ctx(ctx.get()) / 2 - 1);
        const auto countTokens = [&](const std::string &s) {
            std::vector<whisper_token> buf(std::max<size_t>(1, s.size()));  // a token consumes at least one byte
            return std::max(0, whisper_tokenize(ctx.get(), s.c_str(), buf.data(), int(buf.size())));
        };
        const std::string prompt = parla::select_prompt(parla::split_lines(terms), capacity, countTokens);
        auto decode = [&]() {
            auto p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
            p.n_threads = std::max(4, std::min(8, int(std::thread::hardware_concurrency()) - 2));
            p.no_timestamps = !parla::decode_timestamps(timed, count); p.print_progress = false; p.print_realtime = false;
            p.print_special = false; p.print_timestamps = false;
            if (timed) {
                p.offset_ms = 0; p.duration_ms = 0; p.single_segment = false; p.token_timestamps = false;
                p.translate = false; p.detect_language = false; p.max_len = 0; p.max_tokens = 0; p.tdrz_enable = false;
            }
            p.language = language.c_str(); p.initial_prompt = prompt.empty() ? nullptr : prompt.c_str();
            p.abort_callback = aborted; p.abort_callback_user_data = token.get();
            // Preserve native temperature fallback/audio-context defaults, as desktop does.
            const auto status = whisper_full(ctx.get(), p, samples.data(), count);
            if (token->canceled.load()) return std::string();
            if (status != 0) throw std::runtime_error("On-device transcription failed");
            if (timed) return timedPayload(ctx.get());
            std::string text;
            for (int i = 0; i < whisper_full_n_segments(ctx.get()); ++i) {
                const auto segment = whisper_full_get_segment_text(ctx.get(), i); if (segment) text += segment;
            }
            return text;
        };
        auto text = decode();
        if (!timed && multi && !pinned && languages > 0 && !token->canceled.load() && !text.empty()) {
            whisper_token sot = whisper_token_sot(ctx.get());
            const char *actual = nullptr;
            if (whisper_decode(ctx.get(), &sot, 1, 0, std::max(4, std::min(8, int(std::thread::hardware_concurrency()) - 2))) == 0) {
                const float *logits = whisper_get_logits(ctx.get());
                if (logits) {
                    int best = 0;
                    for (int i = 1; i < languages && i <= whisper_lang_max_id(); ++i)
                        if (logits[whisper_token_lang(ctx.get(), i)] > logits[whisper_token_lang(ctx.get(), best)]) best = i;
                    actual = whisper_lang_str(best);
                }
            }
            if (actual && language != actual) { language = actual; lastLanguage = language; text = decode(); }
        }
        if (token->canceled.load()) return nullptr;
        // Standard UTF-8 bytes, never JNI Modified UTF-8: emoji and Indic text survive unchanged.
        auto result = env->NewByteArray(static_cast<jsize>(text.size()));
        if (result) env->SetByteArrayRegion(result, 0, static_cast<jsize>(text.size()), reinterpret_cast<const jbyte *>(text.data()));
        return result;
    } catch (const std::exception &e) { failure(env, e.what()); return nullptr; }
    catch (...) { failure(env, "Native recognition failed"); return nullptr; }
}
}
extern "C" JNIEXPORT jbyteArray JNICALL Java_dev_parla_android_WhisperJni_recognize(JNIEnv *env, jobject, jlong id, jbyteArray modelBytes, jfloatArray sampleArray, jbyteArray promptBytes, jbyteArray languageBytes) {
    return recognize(env, id, modelBytes, sampleArray, promptBytes, languageBytes, false);
}
extern "C" JNIEXPORT jbyteArray JNICALL Java_dev_parla_android_WhisperJni_recognizeTimed(JNIEnv *env, jobject, jlong id, jbyteArray modelBytes, jfloatArray sampleArray, jbyteArray promptBytes, jbyteArray languageBytes) {
    return recognize(env, id, modelBytes, sampleArray, promptBytes, languageBytes, true);
}
// Safe Start's explicit "Try loading once": init and free only, no audio. Same serial lifecycle lock as recognize.
extern "C" JNIEXPORT jboolean JNICALL Java_dev_parla_android_WhisperJni_prepare(JNIEnv *env, jobject, jbyteArray modelBytes) {
    try {
        std::lock_guard<std::mutex> lock(inferenceMutex);
        const auto model = bytes(env, modelBytes, 8192);
        std::unique_ptr<whisper_context, decltype(&whisper_free)> ctx(load(model), whisper_free);
        return ctx ? JNI_TRUE : JNI_FALSE;
    } catch (const std::exception &e) { failure(env, e.what()); return JNI_FALSE; }
    catch (...) { failure(env, "Native model load failed"); return JNI_FALSE; }
}
