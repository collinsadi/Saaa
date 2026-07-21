// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "ClaudeBridge",
    platforms: [.macOS(.v15)],
    products: [.library(name: "ClaudeBridge", targets: ["ClaudeBridge"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "ClaudeBridge", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "ClaudeBridgeTests", dependencies: ["ClaudeBridge"]),
    ]
)
