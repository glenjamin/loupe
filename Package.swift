// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Loupe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.11.1"),
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", exact: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", exact: "0.25.0"),
        // CSS, JavaScript and YAML are held at the last releases that list their
        // scanner.c explicitly; later manifests probe for it relative to the wrong
        // directory and leave it out, so linking fails.
        .package(url: "https://github.com/tree-sitter/tree-sitter-javascript", exact: "0.23.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-ruby", exact: "0.23.1"),
        // Only this tag carries the generated parser.
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", exact: "0.7.4-with-generated-files"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-json", exact: "0.24.8"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-yaml", exact: "0.7.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-bash", exact: "0.25.1"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-css", exact: "0.23.2"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-html", exact: "0.23.2"),
    ],
    targets: [
        .target(
            name: "LoupeCore",
            dependencies: [
                "SwiftTreeSitter",
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterJavaScript", package: "tree-sitter-javascript"),
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                .product(name: "TreeSitterRuby", package: "tree-sitter-ruby"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterJSON", package: "tree-sitter-json"),
                .product(name: "TreeSitterYAML", package: "tree-sitter-yaml"),
                .product(name: "TreeSitterBash", package: "tree-sitter-bash"),
                .product(name: "TreeSitterCSS", package: "tree-sitter-css"),
                .product(name: "TreeSitterHTML", package: "tree-sitter-html"),
            ]
        ),
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
