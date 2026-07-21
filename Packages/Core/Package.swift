// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Core", targets: ["Core"])],
    targets: [
        .target(name: "Core"),
        .testTarget(name: "CoreTests", dependencies: ["Core"]),
    ]
)
