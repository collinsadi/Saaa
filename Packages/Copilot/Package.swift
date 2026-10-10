// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Copilot",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Copilot", targets: ["Copilot"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../AnthropicKit"),
        .package(path: "../Transcription"),
    ],
    targets: [
        .target(
            name: "Copilot",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "AnthropicKit", package: "AnthropicKit"),
                .product(name: "Transcription", package: "Transcription"),
            ]),
        .testTarget(name: "CopilotTests", dependencies: ["Copilot"]),
    ]
)
