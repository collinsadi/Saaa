// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "AnthropicKit",
    platforms: [.macOS(.v26)],
    products: [.library(name: "AnthropicKit", targets: ["AnthropicKit"])],
    targets: [
        .target(name: "AnthropicKit"),
        .testTarget(name: "AnthropicKitTests", dependencies: ["AnthropicKit"]),
    ]
)
