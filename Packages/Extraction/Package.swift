// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Extraction",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Extraction", targets: ["Extraction"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "Extraction", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "ExtractionTests", dependencies: ["Extraction"]),
    ]
)
