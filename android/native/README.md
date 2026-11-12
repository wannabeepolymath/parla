# Pinned local recognition source

`vendor/whisper` contains unmodified CPU sources, headers, CMake modules and licenses from whisper.cpp **v1.9.1**, revision `f049fff95a089aa9969deb009cdd4892b3e74916`, including its in-tree ggml. Upstream archive SHA-256: `279af4ce60dbf397362868f3bacc75b56a4332ac2541cae155070093f6aaf0e3`. See `source-manifest.json` for per-file hashes; licenses remain at `vendor/whisper/LICENSE` and `vendor/whisper/ggml/LICENSE`.

`python3 android/native/prepare-source.py` reproduces the source from the exact revision and verifies the archive before extracting. It downloads source only, never a speech model. The script leaves its verified source archive in this directory; the implementation session removed its own archive after extraction. GPU backends, tests, examples, models, tooling and other unrelated trees are omitted. Do not edit vendored source to implement app policy.

Gradle pins SDK CMake 3.22.1 and NDK 27.1.12297006 (r27b). `CMakeLists.txt` compiles a static CPU backend into `libparla-whisper.so` for arm64-v8a and x86_64, with armv8-a / baseline x86_64, no host-native march, OpenMP, GPU, curl, server, examples or upstream tests. Flexible page sizes and a 16KiB linker maximum-page-size are enabled. Actual packaged ELF alignment and Android loading still need a native link/package/device check.

JNI exchanges standard UTF-8 byte arrays with Kotlin; it never uses JNI Modified UTF-8 for speech. Registry IDs address shared cancellation tokens, never native pointers. Context, PCM, strings and abort userdata live until actual native return. Abort only reads a native atomic. Native init is not cancellable. Kotlin revokes delivery immediately and keeps a process-owned executor barrier through actual exit before another init/decode/model mutation. Contexts unload after each recognition. All JNI entrypoints contain exceptions.

After Gradle CMake configuration, `python3 android/native/check-compile.py` runs each generated translation unit through its pinned NDK compiler with `-fsyntax-only`. This checks both ABIs without linking/assembling or loading a model. It is not a native execution test.
