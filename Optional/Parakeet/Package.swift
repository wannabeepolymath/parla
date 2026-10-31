// swift-tools-version: 6.2
import PackageDescription

// Independent package: never add this dependency to the macOS 13.3 root package.
let package = Package(
    name: "ParlaParakeet",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ParlaParakeetHelper", targets: ["ParlaParakeetHelper"])],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git",
                 revision: "503b4bd1bbf7220882de39fe8ae6716aae4132da", traits: []),
    ],
    targets: [
        .target(name: "ParakeetHelper", dependencies: [.product(name: "FluidAudio", package: "FluidAudio")]),
        .executableTarget(name: "ParlaParakeetHelper", dependencies: ["ParakeetHelper"]),
        .testTarget(name: "ParakeetHelperTests", dependencies: ["ParakeetHelper"]),
    ]
)
