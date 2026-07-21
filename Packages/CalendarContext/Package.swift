// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "CalendarContext",
    platforms: [.macOS(.v15)],
    products: [.library(name: "CalendarContext", targets: ["CalendarContext"])],
    dependencies: [.package(path: "../Core")],
    targets: [
        .target(name: "CalendarContext", dependencies: [.product(name: "Core", package: "Core")]),
        .testTarget(name: "CalendarContextTests", dependencies: ["CalendarContext"]),
    ]
)
