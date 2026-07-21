// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "Persistence",
    platforms: [.macOS(.v15)],
    products: [.library(name: "Persistence", targets: ["Persistence"])],
    dependencies: [.package(path: "../Core"), .package(path: "../ClaudeBridge"), .package(path: "../Matching")],
    targets: [
        .target(name: "Persistence", dependencies: [.product(name: "Core", package: "Core"), .product(name: "ClaudeBridge", package: "ClaudeBridge"), .product(name: "Matching", package: "Matching")]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
    ]
)
