// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/CodeEditApp/CodeEditLanguages", exact: "0.1.20"),
    ],
    targets: [
        .target(
            name: "LoupeCore",
            dependencies: [
                "LoupeModel",
                "SwiftTreeSitter",
                "CodeEditLanguages",
                "TreeSitterProto",
                "TreeSitterHCL",
                "TreeSitterGraphQL",
            ],
            resources: [.copy("Resources/linguist"), .copy("Resources/quote-selection.js"), .copy("Resources/quote-reply.js"), .copy("Resources/relative-times.js")],
            swiftSettings: strictSwift()
        ),
        // Protocol Buffers, which CodeEditLanguages lacks, vendored by Scripts/update-tree-sitter-proto.sh.
        .target(
            name: "TreeSitterProto",
            exclude: ["LICENSE", "README.md", "VERSION"],
            sources: ["src/parser.c"],
            resources: [.copy("queries")],
            cSettings: [.headerSearchPath("src")]
        ),
        // HCL, for Terraform, which CodeEditLanguages lacks, vendored by Scripts/update-tree-sitter-hcl.sh.
        .target(
            name: "TreeSitterHCL",
            exclude: ["LICENSE", "LICENSE-queries", "README.md", "VERSION"],
            sources: ["src/parser.c", "src/scanner.c"],
            resources: [.copy("queries")],
            cSettings: [.headerSearchPath("src")]
        ),
        // GraphQL, which CodeEditLanguages lacks, vendored by Scripts/update-tree-sitter-graphql.sh.
        .target(
            name: "TreeSitterGraphQL",
            exclude: ["LICENSE", "README.md", "VERSION"],
            sources: ["src/parser.c"],
            resources: [.copy("queries")],
            cSettings: [.headerSearchPath("src")]
        ),
        .target(name: "LoupeModel", swiftSettings: strictSwift()),
        .target(name: "LoupeGitHub", dependencies: ["LoupeModel"], swiftSettings: strictSwift()),
        .target(name: "LoupeStore", dependencies: ["LoupeModel", .product(name: "GRDB", package: "GRDB.swift")], swiftSettings: strictSwift()),
        .target(name: "LoupeGit", dependencies: ["LoupeCore", "LoupeStore"], swiftSettings: strictSwift()),
        .target(name: "LoupeInbox", dependencies: ["LoupeCore", "LoupeModel", "LoupeGitHub", "LoupeStore", "LoupeGit"], swiftSettings: strictSwift()),
        // The fake GitHub serving probe/'s anonymised captures, and the git repos behind them: the
        // tests' GitHub, and a snapshot run's with LOUPE_FIXTURES set.
        .target(name: "LoupeFakeGitHub", dependencies: ["LoupeModel", "LoupeGitHub"], swiftSettings: strictSwift()),
        .executableTarget(
            name: "Loupe",
            dependencies: ["LoupeCore", "LoupeModel", "LoupeStore", "LoupeGit", "LoupeGitHub", "LoupeInbox", "LoupeFakeGitHub"],
            resources: [
                .copy("Resources/Loupe.icns"),
                .copy("Resources/conversation.html"),
                .copy("Resources/conversation.css"),
            ],
            swiftSettings: strictSwift()
        ),
        .testTarget(name: "LoupeTests", dependencies: ["LoupeCore", "LoupeModel"], exclude: ["Fixtures"], swiftSettings: strictSwift()),
        .testTarget(name: "LoupeInboxTests", dependencies: ["LoupeCore", "LoupeModel", "LoupeGitHub", "LoupeStore", "LoupeGit", "LoupeInbox", "LoupeFakeGitHub"], swiftSettings: strictSwift()),
    ]
)

/// Every Swift target of ours gets these: warnings are errors, so they get fixed rather than pile up.
/// Not for dependencies or the vendored C grammar, and the linker's warnings about CodeEditLanguages' grammars are untouched.
func strictSwift() -> [SwiftSetting] {
    [.unsafeFlags(["-warnings-as-errors"])]
}
