# Verification

Date: 2026-11-05. Static checks only. Nothing was built, linked, installed, run on a simulator or device, downloaded or decoded.

## Run

| Command | Result | What it proves |
|---|---|---|
| `python3 Scripts/generate_project.py` | writes 5 targets | deterministic project output |
| `plutil -lint Parla.xcodeproj/project.pbxproj` | OK | the project file parses |
| `python3 Scripts/validate_project.py` | PASS | every file reference exists; ParlaCore holds exactly the shim, listed desktop files and whisper sources; the app links it, extensions do not; iOS 26.0 everywhere; module map resolves relatively; plists, cues, icon and naming |
| `python3 Scripts/typecheck.py` | PASS, 7 stages | see below |

`typecheck.py` stages, all for `arm64-apple-ios26.0`, Swift 5 mode, warnings as errors:

1. `parlacore`: `swiftc -typecheck` of the shim plus the desktop files.
2. `parlacore-interface`: `-emit-module -experimental-skip-non-inlinable-function-bodies`, only to give the app a module to import.
3. `app`: `-emit-module` of Shared + App against that interface, which also runs whole-module SIL diagnostics on the app's own code.
4. `keyboard`, `widgets`: `-typecheck -application-extension` (no ParlaCore).
5. `test-sources`: tests compiled with the app sources against XCTest and ParlaCore.
6. `whisper-ggml-syntax`: `clang -fsyntax-only` / `clang++ -fsyntax-only` over all 26 whisper/ggml sources with the project's defines and include paths.

Logs and results are written to `evidence/implementation/` (git-ignored).

## Focused regression sources

`Tests/ParlaTests.swift` includes storage-failure delivery and local retention before a failed shared write; cancellation/replacement ownership; exact UTF-8 result limits, oversized-file refusal and worst-case JSON escaping; background-task completion/expiration; cancelled/dismissed editor drafts; Apple Speech capacity and refused reservations; and synthetic URLProtocol fixtures for chunked/declared response limits, `/models` GET discovery and credential-bearing 307/308 redirects. These tests are type-checked only, not executed. Keyboard view teardown, clipboard delivery, Speech asset release and real iOS background expiration still require runtime verification.

## Not verified

- No Xcode build, link or archive: duplicate C basenames (`quants.c`, `repack.cpp`) in one target, `-lc++`/Accelerate linking, Swift static-library + C++ mixing and test-host symbol visibility are unexercised.
- Desktop bodies are type-checked but not lowered to SIL in stage 1–2; SIL-only errors in desktop files would surface only in a real build.
- No model was downloaded, hashed on device, loaded or decoded; whisper speed, memory and accuracy on iPhone CPUs are unknown. Large v3 Turbo may be too slow or too large on some devices.
- Apple Speech (`SpeechAnalyzer`) asset reservation, download and recognition, and Apple Intelligence cleanup availability, were not exercised.
- No microphone capture, resampling of real hardware buffers, cue playback, background processing time, Live Activity, widget, intent or keyboard handoff was run.
- Keychain behavior on device (access group, `LAContext` interaction flags) and protected-file classes were not observed.
- Unit tests type-check but were not executed.
- No network request to Hugging Face or any cleanup provider was made.
