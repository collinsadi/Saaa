// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ScreenContext",
    platforms: [.macOS(.v26)],
    products: [.library(name: "ScreenContext", targets: ["ScreenContext"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "ScreenContext", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "ScreenContextTests", dependencies: ["ScreenContext"]),
    ]
)
