// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
    ],
    targets: [
        .target(name: "LoupeCore"),
        .target(name: "LoupeModel"),
        .target(name: "LoupeGitHub", dependencies: ["LoupeModel"]),
        .target(name: "LoupeStore", dependencies: ["LoupeModel", .product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "LoupeGit", dependencies: ["LoupeStore"]),
        .target(name: "LoupeInbox", dependencies: ["LoupeCore", "LoupeModel", "LoupeGitHub", "LoupeStore", "LoupeGit"]),
        .executableTarget(
            name: "Loupe",
            dependencies: ["LoupeCore", "LoupeModel", "LoupeStore", "LoupeInbox"],
            resources: [.copy("Resources/Loupe.icns")]
        ),
        .testTarget(name: "LoupeTests", dependencies: ["LoupeCore"], exclude: ["Fixtures"]),
        .testTarget(name: "LoupeInboxTests", dependencies: ["LoupeCore", "LoupeModel", "LoupeGitHub", "LoupeStore", "LoupeGit", "LoupeInbox"]),
    ]
)
