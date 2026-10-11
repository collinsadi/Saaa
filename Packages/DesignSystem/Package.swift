// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [.macOS(.v26)],
    products: [.library(name: "DesignSystem", targets: ["DesignSystem"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "DesignSystem", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "DesignSystemTests", dependencies: ["DesignSystem"]),
    ]
)
