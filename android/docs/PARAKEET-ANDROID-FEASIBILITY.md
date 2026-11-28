# Parakeet on Android: feasibility (P2-07)

Research only, 2026-11-28. No product code, setting or download was added. The verdict below is the reason `Models.kt` still has no recognition-engine choice.

## Verdict

**Feasible, but not a small change, and not shipped.** Supported Android runtimes for `nvidia/parakeet-tdt-0.6b-v3` do exist. Three are viable: sherpa-onnx, LiteRT/MediaPipe and ExecuTorch. None of them is in the app today, though.

Adopting one means adding a second native runtime, a new pinned model artifact of about 615–640 MB, and a model that needs about 0.8–2 GB of RAM.

The Mac's Parakeet is not portable to Android:
- Its exact artifact, `tdt-0.6b-v3-int4`, is an Apple CoreML/MLX build.
- It runs through a signed helper process with its own wire protocol ([ParakeetWire.swift:8](../../Sources/ParlaCore/ParakeetWire.swift), [RecognitionFactory.swift:102](../../Sources/ParlaCore/RecognitionFactory.swift)).

**Recommendation.** Keep Parakeet unselectable on Android until one runtime has been built into this app and measured on a real 4–6 GB arm64 phone. The best first candidate is sherpa-onnx with the official int8 package. It covers both of our ABIs and uses Apache-2.0 code.

## What the Mac uses, and why it doesn't carry over

- The model is `tdt-0.6b-v3-int4`, pinned by manifest and revision. It has a fixed language filter of 25 European languages ([ParakeetWire.swift:8](../../Sources/ParlaCore/ParakeetWire.swift)).
- The int4 Parakeet builds that exist are Apple-only:
  - CoreML `EncoderInt4.mlmodelc`, for macOS 15 / iOS 18: https://huggingface.co/1of2/parakeet-tdt-0.6b-v3-coreml
  - MLX: https://huggingface.co/sonic-speech/parakeet-tdt-0.6b-v3-int4
- Android therefore needs a different artifact. It would have a different hash and possibly different accuracy, so it can't reuse the Mac's identity or pin.

## The model

| Item | Value | Source |
|---|---|---|
| Licence | CC BY 4.0 (attribution required), "ready for commercial/non-commercial use" | https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3 |
| Size | ~0.6 B parameters | same |
| Input | 16 kHz mono | same |
| Languages | bg hr cs da nl en et fi fr de el hu it lv lt mt pl pt ro sk sl es sv ru uk, auto-detected | same |
| Android in model card | Not mentioned. The card targets NVIDIA GPUs and Linux, and lists a GGUF build for NVIDIA's NeMo-Speech.cpp | same |

## Candidate runtimes

### 1. sherpa-onnx (k2-fsa): best fit

- **Runtime.** Apache-2.0, with a Kotlin `OfflineRecognizer` and the model loaded as `nemo_transducer`. https://github.com/k2-fsa/sherpa-onnx
- **Latest release.** v2.0.3, published 2026-11-22. https://api.github.com/repos/k2-fsa/sherpa-onnx/releases/latest
  - `sherpa-onnx-2.0.3.aar`: 52.4 MB
  - `sherpa-onnx-static-link-onnxruntime-2.0.3.aar`: 40.0 MB
  - `sherpa-onnx-v2.0.3-android.tar.bz2` (prebuilt `.so` files): 48.0 MB
- **Model package.** `sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2` from the `asr-models` release. https://k2-fsa.github.io/sherpa/onnx/pretrained_models/offline-transducer/nemo-transducer-models.html

  | File | Size |
  |---|---|
  | `encoder.int8.onnx` | 622M |
  | `decoder.int8.onnx` | 12M |
  | `joiner.int8.onnx` | 6.1M |
  | `tokens.txt` | 92K |
  | **Total** | **640M** |

  The docs list only int8 for v3. v2 (English only) also has fp16 and fp32 packages.
- **ABIs.** The build scripts cover arm64-v8a, armeabi-v7a, x86_64 and x86. https://k2-fsa.github.io/sherpa/onnx/android/build-sherpa-onnx.html
  - One third-party app had to add x86_64 libraries from the release tarball itself, so check the AAR's `jni/` contents before relying on it. https://github.com/getdictus/dictus-android/issues/324
- **16 KB pages.** Support arrived in 1.12.10, according to the changelog. https://github.com/k2-fsa/sherpa-onnx/blob/master/CHANGELOG.md
  - Don't add Microsoft's `onnxruntime-android` alongside it, because that package brings a second, misaligned JNI library. https://github.com/k2-fsa/sherpa-onnx/issues/3291
- **Memory: the main risk.** The only measurement I found is third-party, on an x86_64 emulator.
  - Load peaks at about 1.5–1.6 GiB, and a 134 s take peaks at about 1.9 GiB (VmHWM up to 2.17).
  - The ONNX Runtime arena stays resident afterwards.
  - A 3 GB AVD soft-rebooted, and a 4 GB AVD survived only after killing about 10 cached apps.
  - The project kept a 6 GB minimum.
  - Source: https://github.com/getdictus/dictus-android/issues/324
- **Speed.** Real-time factor (RTF, lower is faster) was quoted from a Pixel 4 at 0.12 for short takes and 0.31 for long ones. The emulator ran at 0.28–0.41. Same source.
- **Mode.** Offline transducer only. "Streaming" means simulated, by chunking with VAD.

### 2. LiteRT / MediaPipe (Google `litert-community`)

- **Artifacts.** https://huggingface.co/litert-community/parakeet-tdt-0.6b-v3
  - `parakeet_tdt_0.6b_v3_5s_i8_stateful.litertlm`: 615 MB, an INT8 bundle that includes the tokenizer
  - Plain INT8 `.tflite`: 614 MB
  - FP32: 2.42 GB
- **Licences.** CC-BY-4.0 for the weights, Apache-2.0 for the runtimes.
- **Android requirements.** `com.google.mediapipe:tasks-audio`, `minSdk 26`, **arm64-v8a only**. That means no x86_64 emulator build, which our test matrix uses.
- **Vendor benchmark.** Galaxy S24 Ultra, INT8, 4-thread CPU: RTF 0.064–0.104 at 765–779 MB peak RAM. This is the lowest memory figure found, but it has not been reproduced independently.
- **Windowing.** Fixed 5 s windows with overlap. Words near a window boundary take about 1–2 s to confirm.

### 3. ExecuTorch (PyTorch)

- **Export.** Exports `nvidia/parakeet-tdt-0.6b-v3`, with XNNPACK and Vulkan backends among others. https://github.com/pytorch/executorch/tree/main/examples/models/parakeet
  - Quantization options are 8da4w and 8da8w for XNNPACK.
  - A demo Android app (ParakeetApp) exists in `meta-pytorch/executorch-examples`.
- **Gaps.** I found no Android memory or latency figures. The demo AAR comes from a CI artifact.
  - An open report says XNNPACK export output differs from NeMo: https://github.com/pytorch/executorch/issues/18281
- This is the least mature path.

### Ruled out

- **NVIDIA Riva.** No on-device Android path. Its support matrix lists Jetson and gRPC clients only. https://docs.nvidia.com/deeplearning/riva/user-guide/docs/support-matrix/support-matrix.html
- **FluidAudio and parakeet-mlx.** Apple only.
- **NeMo-Speech.cpp GGUF** (`q8_0`, about 714 MB). One community Android app uses it, but it is arm64 only, and its optimised builds crash on CPUs without dotprod/i8mm. https://github.com/meet30997/parakeet-android-on-device-speech-recognition

## What adopting sherpa-onnx would take

1. **Native.** Vendor `libsherpa-onnx-jni.so` and `libonnxruntime.so` for arm64-v8a and x86_64, pinned by hash.
   - It is independent of `libparla-whisper.so`, so whisper.cpp and `bridge.cpp` stay as they are.
   - The APK grows by tens of MB, against the current 36 MB debug APK.
   - Verify 16 KB `LOAD` alignment with `llvm-readelf -lW`.
2. **Artifact.** Add four new pinned files (about 640 MB) to `ModelCatalog`/`ModelTransfer`. This changes the catalog, which today assumes one ggml file per model and at most three entries ([ModelTransfer.kt](../app/src/main/java/dev/parla/android/ModelTransfer.kt) `init`).
   - The int8 archive was reportedly re-published upstream. Pin by hash at the time you adopt it, and refuse anything else.
3. **Engine.** Add a typed recognition backend in `LocalSpeech.kt`/`Models.kt`, running on the same serial `NativeTasks` owner.
   - Safe Start markers must wrap its load and decode as well.
   - The language filter must match the Mac's list, with no translation.
4. **Memory gate.** Allow the backend only on devices that pass a measured RAM threshold (likely 6 GB, see the third-party data above). Release the recognizer after each use, the way whisper contexts are released today.
5. **Licence.** Show CC BY 4.0 attribution in the app.
6. **Qualification.** Before the setting becomes selectable, measure on a real arm64 phone: memory, real-time factor and accuracy against Whisper on the same clips.

## Not confirmed

- Whether the 2.0.3 AAR ships x86_64 JNI libraries, and which ONNX Runtime version it bundles.
- The sherpa-onnx AAR's minSdk.
- Any memory figure for sherpa-onnx v3 int8 from a real mid-range phone. The numbers above come from an emulator, a Pixel 4, or a vendor S24 Ultra run for LiteRT.
- int8 accuracy on our languages. A community card reports accuracy loss for far-field and non-English speech: https://huggingface.co/fyychs/parakeet-tdt-0.6b-v3-nbits-sherpa-onnx
