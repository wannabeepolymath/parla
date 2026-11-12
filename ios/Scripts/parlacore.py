"""ParlaCore-for-iOS inputs shared by generate_project.py, typecheck.py and validate_project.py.

The desktop Swift files are referenced unmodified from ../Sources/ParlaCore. The macOS-only files
AudioRecorder, ClipboardDelivery, Inserter, Hotkey, ShortcutDisplay and ParakeetTrust are excluded;
Sources/Core/ParlaCoreIOS.swift supplies the few declarations the shared files name.
whisper.cpp v1.9.1 is the copy the Android app vendors; this list mirrors its static CPU-only build
(ggml-base + ggml + ggml-cpu + whisper; no Metal, BLAS, OpenMP, KleidiAI or parakeet).
Local dispatch files select ARM kernels on iPhone/Apple Silicon and x86 kernels on Intel Simulator."""
CORE_SWIFT = '''ActivityShadow AppleIntelligenceCleanup AppleSpeechAssets AppleSpeechNative AppleSpeechRecognition Cleanup
CleanupFactory CleanupFailover Credentials Diagnostics Eval GuidedTemplate History HistoryRetry HistoryRetryHTTP HistoryRetrySegmentation
ModelCatalog MouseInput OpenAICompatClient ParakeetInstallation ParakeetModelManifest ParakeetProcess ParakeetRecognition
ParakeetWire ParakeetWorker PendingOperation Pipeline PreparationBuild Profiles RecognitionFactory RecognitionIdentity
RecognitionPreparation RecognitionPreviewPlan RecognitionRequest RecognitionSegments RecordingStore
ScratchpadDictionaryConfiguration Settings Streaming TextRules Trace Transcriber SurroundingTextContext Transforms Vocabulary VocabularyTransfer'''.split()
CORE_DIR = '../Sources/ParlaCore'
SHIM = 'Sources/Core/ParlaCoreIOS.swift'
MODULE_MAP_DIR = 'Sources/Core/whisper'
VENDOR = '../android/native/vendor/whisper'
WHISPER_SOURCES = [
    'src/whisper.cpp',
    'ggml/src/ggml.c', 'ggml/src/ggml.cpp', 'ggml/src/ggml-alloc.c', 'ggml/src/ggml-backend.cpp', 'ggml/src/ggml-backend-meta.cpp',
    'ggml/src/ggml-opt.cpp', 'ggml/src/ggml-threading.cpp', 'ggml/src/ggml-quants.c', 'ggml/src/gguf.cpp',
    'ggml/src/ggml-backend-reg.cpp', 'ggml/src/ggml-backend-dl.cpp',
    'ggml/src/ggml-cpu/ggml-cpu.c', 'ggml/src/ggml-cpu/ggml-cpu.cpp', 'ggml/src/ggml-cpu/repack.cpp', 'ggml/src/ggml-cpu/hbm.cpp',
    'ggml/src/ggml-cpu/quants.c', 'ggml/src/ggml-cpu/traits.cpp', 'ggml/src/ggml-cpu/amx/amx.cpp', 'ggml/src/ggml-cpu/amx/mmq.cpp',
    'ggml/src/ggml-cpu/binary-ops.cpp', 'ggml/src/ggml-cpu/unary-ops.cpp', 'ggml/src/ggml-cpu/vec.cpp', 'ggml/src/ggml-cpu/ops.cpp',
]
CPU_DISPATCH = ['Sources/Core/CPUQuants.c', 'Sources/Core/CPURepack.cpp']
# Swift's clang importer sees only these (whisper.h and the ggml headers it includes).
PUBLIC_INCLUDES = ['include', 'ggml/include']
PRIVATE_INCLUDES = ['ggml/src', 'ggml/src/ggml-cpu', 'src']
# CMake's definitions for this configuration. Accelerate is ggml's Apple default (vDSP in ggml-cpu); C/C++ only, never Swift.
DEFINES = ['GGML_SCHED_MAX_COPIES=4', '_XOPEN_SOURCE=600', '_DARWIN_C_SOURCE', 'GGML_USE_CPU', 'GGML_USE_CPU_REPACK',
           'GGML_USE_ACCELERATE', 'ACCELERATE_NEW_LAPACK', 'ACCELERATE_LAPACK_ILP64',
           'GGML_VERSION="0.15.1"', 'GGML_COMMIT="unknown"', 'WHISPER_VERSION="1.9.1"']
C_STANDARD, CXX_STANDARD = 'gnu11', 'gnu++17'
DEPLOYMENT = '26.0'

def core_paths():
    return [f'{CORE_DIR}/{name}.swift' for name in CORE_SWIFT]

def vendor_paths():
    return [f'{VENDOR}/{path}' for path in WHISPER_SOURCES]

def native_paths():
    return vendor_paths() + CPU_DISPATCH
