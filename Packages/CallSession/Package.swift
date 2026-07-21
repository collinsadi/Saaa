// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CallSession",
    platforms: [.macOS(.v15)],
    products: [.library(name: "CallSession", targets: ["CallSession"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../AudioCapture"),
        .package(path: "../Transcription"),
    ],
    targets: [
        .target(
            name: "CallSession",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription"),
            ]),
        .testTarget(name: "CallSessionTests", dependencies: ["CallSession"]),
    ]
)
