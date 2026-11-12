// Repack must use the same architecture as the quantization kernels.
#if defined(__aarch64__)
#include "../../../android/native/vendor/whisper/ggml/src/ggml-cpu/arch/arm/repack.cpp"
#elif defined(__x86_64__)
#include "../../../android/native/vendor/whisper/ggml/src/ggml-cpu/arch/x86/repack.cpp"
#else
#error Unsupported Parla CPU architecture
#endif
