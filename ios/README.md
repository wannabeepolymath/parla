# Parla for iPhone

Native SwiftUI app, UIKit keyboard and WidgetKit/ActivityKit extension. Dictation runs on the desktop Parla core: the app compiles the unmodified desktop `Sources/ParlaCore` Swift files and the whisper.cpp v1.9.1 CPU sources into a `ParlaCore` static library. Speech is recognized on the iPhone; cleanup is optional (Apple Intelligence on device, or Anthropic / OpenAI-compatible with your own key). iOS 26.0 minimum for every target. No third-party dependencies and no sign-in.

```sh
python3 Scripts/generate_project.py   # writes Parla.xcodeproj (five targets)
python3 Scripts/typecheck.py          # Swift type checks + clang -fsyntax-only; no build
python3 Scripts/validate_project.py   # project/resource structure checks
python3 Scripts/make_cues.py          # regenerates the start/stop cue WAVs
```

For a physical iPhone, set `DEVELOPMENT_TEAM`, `PARLA_BUNDLE_PREFIX` and `PARLA_APP_GROUP` locally in `Configuration/Signing.xcconfig`. Simulator commands below need no team.

- [Implementation](docs/IMPLEMENTATION.md): targets, the shared desktop core, recognition, cleanup, capture, keyboard handoff.
- [Verification](docs/VERIFICATION.md): Simulator builds, executed tests, screen evidence and remaining device/model checks.

The project references files outside `ios/` by relative path: `../Sources/ParlaCore/*.swift` (desktop core) and `../android/native/vendor/whisper` (pinned whisper.cpp). Both must be present at those paths to build.

## Simulator

From `ios/`, with Xcode 26.6 and the iPhone 17 Simulator installed:

```sh
xcodebuild -project Parla.xcodeproj -scheme Parla -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath evidence/simulator/DerivedData \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
xcodebuild -project Parla.xcodeproj -scheme Parla -configuration Debug -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath evidence/simulator/DerivedData \
  -parallel-testing-enabled NO CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= test
```

Ad-hoc signing needs no development team or provisioning profile and preserves the simulated App Group entitlements. `CODE_SIGNING_ALLOWED=NO` builds and runs the app, but App Group access is refused at runtime. Physical-device signing still needs your own team configured locally.
