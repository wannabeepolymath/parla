# Parla for iPhone

Native SwiftUI app, UIKit keyboard and WidgetKit/ActivityKit extension. Dictation runs on the desktop Parla core: the app compiles the unmodified desktop `Sources/ParlaCore` Swift files and the whisper.cpp v1.9.1 CPU sources into a `ParlaCore` static library. Speech is recognized on the iPhone; cleanup is optional (Apple Intelligence on device, or Anthropic / OpenAI-compatible with your own key). iOS 26.0 minimum for every target. No third-party dependencies and no sign-in.

```sh
python3 Scripts/generate_project.py   # writes Parla.xcodeproj (five targets)
python3 Scripts/typecheck.py          # Swift type checks + clang -fsyntax-only; no build
python3 Scripts/validate_project.py   # project/resource structure checks
python3 Scripts/make_cues.py          # regenerates the start/stop cue WAVs
```

Set `DEVELOPMENT_TEAM`, `PARLA_BUNDLE_PREFIX` and `PARLA_APP_GROUP` in `Configuration/Signing.xcconfig`.

- [Implementation](docs/IMPLEMENTATION.md): targets, the shared desktop core, recognition, cleanup, capture, keyboard handoff.
- [Verification](docs/VERIFICATION.md): what was checked, and what was not (no build, link, device run or model decode).

The project references files outside `ios/` by relative path: `../Sources/ParlaCore/*.swift` (desktop core) and `../android/native/vendor/whisper` (pinned whisper.cpp). Both must be present at those paths to build.
