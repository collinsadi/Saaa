// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Matching",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Matching", targets: ["Matching"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "Matching", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "MatchingTests", dependencies: ["Matching"]),
    ]
)
