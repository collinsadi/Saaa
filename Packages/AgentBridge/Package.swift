// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AgentBridge",
    platforms: [.macOS(.v15)],
    products: [.library(name: "AgentBridge", targets: ["AgentBridge"])],
    dependencies: [
        .package(path: "../Core"),
        .package(path: "../ClaudeBridge"),
        .package(path: "../Matching"),
    ],
    targets: [
        .target(
            name: "AgentBridge",
            dependencies: [
                .product(name: "Core", package: "Core"),
                .product(name: "ClaudeBridge", package: "ClaudeBridge"),
                .product(name: "Matching", package: "Matching"),
            ]),
        .testTarget(name: "AgentBridgeTests", dependencies: ["AgentBridge"]),
    ]
)
