// Host self-check for the "parla:" loader bounds in vendor/whisper/src/whisper.cpp. Crafted files must be
// refused (nullptr) without crashing. Build and run on the host: sh android/native/loader-bounds-test.sh
// Against unpatched v1.9.1, n_dims-99 segfaults, vocab-size hangs, and four other cases load.
#include <whisper.h>
#include <algorithm>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <string>
#include <vector>

namespace {
struct Bytes {
    std::vector<char> b;
    Bytes &i(int32_t v) { for (int k = 0; k < 4; ++k) b.push_back(char((uint32_t(v) >> (8 * k)) & 0xff)); return *this; }
    Bytes &s(const std::string &v) { b.insert(b.end(), v.begin(), v.end()); return *this; }
    Bytes &zeros(size_t n) { b.insert(b.end(), n, 0); return *this; }
};
// tiny.en-shaped hparams (passes the Kotlin header check), then mel filters and a one-word vocab.
Bytes header() {
    Bytes w; w.i(0x67676d6c);
    for (int32_t v : {51864, 1500, 384, 6, 4, 448, 384, 6, 4, 80, 0}) w.i(v);
    return w;
}
Bytes prefix(int32_t n_fft = 201, int32_t n_vocab = 1, int32_t word = 1) {
    Bytes w = header(); w.i(80).i(n_fft).zeros(size_t(80) * 201 * sizeof(float));
    w.i(n_vocab).i(word); if (word == 1) w.s("a");
    return w;
}
int failures = 0;
const char *only = nullptr; // optional third argument: run one case
void refused(const std::string &dir, const char *name, const Bytes &w) {
    if (only && std::string(only) != name) return;
    const std::string path = dir + "/" + name + ".bin";
    std::ofstream(path, std::ios::binary).write(w.b.data(), std::streamsize(w.b.size()));
    auto params = whisper_context_default_params(); params.use_gpu = false;
    whisper_context *ctx = whisper_init_from_file_with_params(path.c_str(), params);
    std::printf("%-26s %s\n", name, ctx ? "LOADED (unexpected)" : "refused");
    if (ctx) { ++failures; whisper_free(ctx); }
}
}

int main(int argc, char **argv) {
    const std::string dir = argc > 1 ? argv[1] : ".";
    if (argc > 2) only = argv[2];
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    whisper_log_set([](ggml_log_level, const char *, void *) {}, nullptr);
    Bytes truncated = header(); truncated.b.resize(30);
    refused(dir, "truncated-hparams", truncated);
    Bytes mel = prefix(); mel.b.resize(header().b.size() + 8 + 1000);
    refused(dir, "truncated-mel", mel);
    refused(dir, "bad-n_fft", prefix(4096));
    refused(dir, "vocab-size", prefix(201, 1 << 30));
    refused(dir, "vocab-word-length", prefix(201, 1, 0x7fffffff));
    Bytes dims = prefix(); dims.i(99).i(4).i(0); for (int k = 0; k < 99; ++k) dims.i(1); dims.s("abcd");
    refused(dir, "n_dims-99", dims);
    Bytes name = prefix(); name.i(1).i(1 << 30).i(0).i(1);
    refused(dir, "name-length-1GiB", name);
    Bytes negative = prefix(); negative.i(2).i(4).i(0).i(-5).i(1).s("abcd");
    refused(dir, "negative-dimension", negative);
    Bytes overflow = prefix(); overflow.i(2).i(4).i(0).i(1 << 20).i(1 << 20).s("abcd");
    refused(dir, "element-count-overflow", overflow);
    Bytes type = prefix(); type.i(1).i(4).i(9999).i(1).s("abcd");
    refused(dir, "tensor-type", type);
    Bytes data = prefix(); data.i(2).i(18).i(0).i(1).i(384).s("encoder.conv1.bias").zeros(100);
    refused(dir, "truncated-tensor-data", data);
    // Positive control: real catalog models still load (PARLA_REAL_MODELS=path1:path2).
    if (const char *real = std::getenv("PARLA_REAL_MODELS")) {
        std::string list = real;
        for (size_t start = 0; start <= list.size();) {
            const size_t end = std::min(list.find(':', start), list.size());
            const std::string path = list.substr(start, end - start); start = end + 1;
            if (path.empty()) continue;
            auto params = whisper_context_default_params(); params.use_gpu = false;
            whisper_context *ctx = whisper_init_from_file_with_params(path.c_str(), params);
            std::printf("real model %s %s\n", path.c_str(), ctx ? "loaded" : "REFUSED (unexpected)");
            if (ctx) whisper_free(ctx); else ++failures;
        }
    }
    std::printf(failures ? "FAILED\n" : "OK\n");
    return failures ? 1 : 0;
}
