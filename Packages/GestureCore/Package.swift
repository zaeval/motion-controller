// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GestureCore",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GestureCore", targets: ["GestureCore"]),
    ],
    targets: [
        .target(name: "GestureCore"),
        .testTarget(name: "GestureCoreTests", dependencies: ["GestureCore"], resources: [.copy("Fixtures")]),
    ]
)
