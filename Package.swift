// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LoupeCore"),
        .executableTarget(name: "Loupe", dependencies: ["LoupeCore"]),
        .testTarget(name: "LoupeTests", dependencies: ["LoupeCore"], exclude: ["Fixtures"]),
    ]
)
