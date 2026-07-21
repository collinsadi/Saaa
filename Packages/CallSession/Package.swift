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
        .package(path: "../CalendarContext"),
        .package(path: "../Matching"),
        .package(path: "../ClaudeBridge"),
    ],
    targets: [
        .target(
            name: "CallSession",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription"),
                .product(name: "CalendarContext", package: "CalendarContext"),
                .product(name: "Matching", package: "Matching"),
                .product(name: "ClaudeBridge", package: "ClaudeBridge"),
            ]),
        .testTarget(name: "CallSessionTests", dependencies: ["CallSession"]),
    ]
)
