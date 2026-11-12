// Match ggml's architecture selection without changing the vendored sources.
#if defined(__aarch64__)
#include "../../../android/native/vendor/whisper/ggml/src/ggml-cpu/arch/arm/quants.c"
#elif defined(__x86_64__)
#include "../../../android/native/vendor/whisper/ggml/src/ggml-cpu/arch/x86/quants.c"
#else
#error Unsupported Parla CPU architecture
#endif
