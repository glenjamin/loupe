// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "LoupeCore"),
        .target(name: "LoupeGitHub"),
        .executableTarget(name: "Loupe", dependencies: ["LoupeCore", "LoupeGitHub"]),
        .testTarget(name: "LoupeTests", dependencies: ["LoupeCore"], exclude: ["Fixtures"]),
        .testTarget(name: "LoupeGitHubTests", dependencies: ["LoupeGitHub"]),
    ]
)
