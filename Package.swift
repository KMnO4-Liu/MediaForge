// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MediaForge",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MediaForgeCore", targets: ["MediaForgeCore"]),
        .executable(name: "MediaForge", targets: ["MediaForge"])
    ],
    targets: [
        .target(name: "MediaForgeCore"),
        .executableTarget(name: "MediaForge", dependencies: ["MediaForgeCore"]),
        .executableTarget(name: "MediaForgeChecks", dependencies: ["MediaForgeCore"], path: "Tests/MediaForgeChecks"),
        .testTarget(name: "MediaForgeCoreTests", dependencies: ["MediaForgeCore"])
    ],
    swiftLanguageModes: [.v5]
)
