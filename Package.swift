// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SwiftRAR",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
        .watchOS(.v10),
        .visionOS(.v1)
    ],
    products: [
        .library(name: "SwiftRAR", targets: ["SwiftRAR"])
    ],
    targets: [
        .target(name: "SwiftRAR"),
        .testTarget(name: "SwiftRARTests", dependencies: ["SwiftRAR"])
    ]
)
