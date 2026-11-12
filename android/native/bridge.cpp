#include <jni.h>
#include <whisper.h>
#include <atomic>
#include <algorithm>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>
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
extern "C" JNIEXPORT jbyteArray JNICALL Java_dev_parla_android_WhisperJni_recognize(JNIEnv *env, jobject, jlong id, jbyteArray modelBytes, jfloatArray sampleArray, jbyteArray promptBytes, jbyteArray languageBytes) {
    try {
        auto token = lookup(id);
        if (!token) throw std::runtime_error("Unknown recognition token");
        // Native init, decode and free are one serial lifecycle. Cancellation never takes this lock.
        std::lock_guard<std::mutex> lock(inferenceMutex);
        if (token->canceled.load()) return nullptr;
        const auto model = bytes(env, modelBytes, 8192);
        if (model != lastModel) { lastLanguage = "en"; lastModel = model; }
        const auto prompt = bytes(env, promptBytes, 2048);
        const auto chosen = bytes(env, languageBytes, 32);
        if (!sampleArray) throw std::runtime_error("No samples");
        const auto count = env->GetArrayLength(sampleArray);
        if (count < 6400 || count > 16000 * 300) throw std::runtime_error("Invalid sample count");
        std::vector<float> samples(count);
        env->GetFloatArrayRegion(sampleArray, 0, count, samples.data());
        if (env->ExceptionCheck()) return nullptr;
        auto cp = whisper_context_default_params(); cp.use_gpu = false; cp.flash_attn = false;
        std::unique_ptr<whisper_context, decltype(&whisper_free)> ctx(whisper_init_from_file_with_params(model.c_str(), cp), whisper_free);
        if (!ctx) throw std::runtime_error("Model could not be loaded. Verify the model or choose a smaller one.");
        // Init cannot abort; token still invalidates delivery immediately and owns state until return.
        if (token->canceled.load()) return nullptr;
        const bool multi = whisper_is_multilingual(ctx.get());
        const bool pinned = chosen != "auto" && whisper_lang_id(chosen.c_str()) >= 0;
        std::string language = !multi ? "en" : pinned ? chosen : lastLanguage;
        auto decode = [&]() {
            auto p = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
            p.n_threads = std::max(4, std::min(8, int(std::thread::hardware_concurrency()) - 2));
            p.no_timestamps = true; p.print_progress = false; p.print_realtime = false;
            p.print_special = false; p.print_timestamps = false;
            p.language = language.c_str(); p.initial_prompt = prompt.empty() ? nullptr : prompt.c_str();
            p.abort_callback = aborted; p.abort_callback_user_data = token.get();
            // Preserve native temperature fallback/audio-context defaults, as desktop does.
            const auto status = whisper_full(ctx.get(), p, samples.data(), count);
            if (token->canceled.load()) return std::string();
            if (status != 0) throw std::runtime_error("On-device transcription failed");
            std::string text;
            for (int i = 0; i < whisper_full_n_segments(ctx.get()); ++i) {
                const auto segment = whisper_full_get_segment_text(ctx.get(), i); if (segment) text += segment;
            }
            return text;
        };
        auto text = decode();
        if (multi && !pinned && !token->canceled.load() && !text.empty()) {
            whisper_token sot = whisper_token_sot(ctx.get());
            const char *actual = nullptr;
            if (whisper_decode(ctx.get(), &sot, 1, 0, std::max(4, std::min(8, int(std::thread::hardware_concurrency()) - 2))) == 0) {
                const float *logits = whisper_get_logits(ctx.get());
                if (logits) {
                    int best = 0;
                    for (int i = 1; i <= whisper_lang_max_id(); ++i)
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
