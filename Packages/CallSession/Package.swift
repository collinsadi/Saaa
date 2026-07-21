// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CallSession",
    platforms: [.macOS(.v15)],
    products: [.library(name: "CallSession", targets: ["CallSession"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "CallSession", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "CallSessionTests", dependencies: ["CallSession"]),
    ]
)
