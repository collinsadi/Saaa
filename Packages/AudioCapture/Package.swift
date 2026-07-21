// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "AudioCapture",
    platforms: [.macOS(.v15)],
    products: [.library(name: "AudioCapture", targets: ["AudioCapture"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "AudioCapture", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "AudioCaptureTests", dependencies: ["AudioCapture"]),
    ]
)
