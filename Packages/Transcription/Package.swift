// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Transcription",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Transcription", targets: ["Transcription"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "Transcription", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "TranscriptionTests", dependencies: ["Transcription"]),
    ]
)
