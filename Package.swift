// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CodexPulse",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "CodexPulse", targets: ["CodexPulse"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "CodexPulseCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "CodexPulse", dependencies: ["CodexPulseCore"]),
        .testTarget(name: "CodexPulseCoreTests", dependencies: ["CodexPulseCore"])
    ]
)
