// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CallSession",
    platforms: [.macOS(.v26)],
    products: [.library(name: "CallSession", targets: ["CallSession"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../AnthropicKit"),
        .package(path: "../AudioCapture"),
        .package(path: "../Transcription"),
        .package(path: "../CalendarContext"),
        .package(path: "../Copilot"),
        .package(path: "../Persistence"),
    ],
    targets: [
        .target(
            name: "CallSession",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "AnthropicKit", package: "AnthropicKit"),
                .product(name: "AudioCapture", package: "AudioCapture"),
                .product(name: "Transcription", package: "Transcription"),
                .product(name: "CalendarContext", package: "CalendarContext"),
                .product(name: "Copilot", package: "Copilot"),
                .product(name: "Persistence", package: "Persistence"),
            ]),
        .testTarget(name: "CallSessionTests", dependencies: ["CallSession"]),
    ]
)
