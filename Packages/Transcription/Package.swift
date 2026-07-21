// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Transcription",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Transcription", targets: ["Transcription"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(
            name: "Transcription",
            dependencies: [
                .product(name: "Core", package: "Core"),
                "whisper",
            ]),
        // whisper.cpp v1.9.1 prebuilt framework, macOS slice only (trimmed
        // from the release asset whisper-v1.9.1-xcframework.zip, sha256
        // 8c3ecbe73f48b0cb9318fc3058264f951ab336fd530e82c4ccdd2298d1311a4c).
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        .testTarget(name: "TranscriptionTests", dependencies: ["Transcription"]),
    ]
)
