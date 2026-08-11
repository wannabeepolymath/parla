// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Parla",
    platforms: [.macOS("13.3")], // matches the v1.9.1 xcframework's min target (silences ld warning)
    targets: [
        // Official whisper.cpp v1.9.1 xcframework (macOS slice only — this is a macOS app).
        // Source-building SwiftPM was dropped upstream at v1.7.5; the release xcframework is
        // the maintained path and embeds the compiled Metal library into the binary (no
        // runtime .metal resource bundle), fixing the v1.7.2 "ggml-common.h missing"
        // breakage so Metal actually initializes. Vendored locally rather than via the
        // release URL because that zip nests the .xcframework under build-apple/, which
        // SPM's remote binaryTarget can't map. Refresh: download whisper-vX-xcframework.zip,
        // keep the macos-arm64_x86_64 slice, trim Info.plist to it.
        .binaryTarget(name: "whisper", path: "Frameworks/whisper.xcframework"),
        // ParlaCore ships its own MIT LICENSE (the app is AGPL); it's documentation
        // living next to the code it covers, not a build input.
        .target(name: "ParlaCore", dependencies: ["whisper"], exclude: ["LICENSE"]),
        .executableTarget(name: "Parla", dependencies: ["ParlaCore"]),
        .executableTarget(name: "parla-eval", dependencies: ["ParlaCore"]),
        // Types known strings into a real app and reads them back — the half of
        // the Tier 0 #8 insertion check that unit tests structurally cannot do.
        .executableTarget(name: "parla-insert-check", dependencies: ["ParlaCore"]),
        .testTarget(name: "ParlaCoreTests", dependencies: ["ParlaCore"]),
    ]
)
