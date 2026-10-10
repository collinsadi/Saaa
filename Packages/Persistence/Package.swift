// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [.macOS(.v26)],
    products: [.library(name: "Persistence", targets: ["Persistence"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "Persistence", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
    ]
)
