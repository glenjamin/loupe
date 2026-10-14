import AppKit
import LoupeCore
import Testing

@MainActor
struct SyntaxHighlightingTests {
    @Test func colorsAGoHunkLikeGitHubOnBothSides() throws {
        let rendered = try showing(greet(path: "greet.go"))

        #expect(colors(of: "func", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "Greet()", in: rendered, length: 5) == [DiffColors.syntaxEntity])
        #expect(colors(of: "// Greet says hello.", in: rendered) == [DiffColors.syntaxComment])
        #expect(colors(of: "\"hello\"", in: rendered) == [DiffColors.syntaxString])
        // Deleted rows are coloured from the old side's code.
        #expect(colors(of: "// Greet says hi.", in: rendered) == [DiffColors.syntaxComment])
        #expect(colors(of: "\"hi\"", in: rendered) == [DiffColors.syntaxString])
        // The surrounding code and the gutter keep their own colours.
        #expect(colors(of: "main", in: rendered) == [NSColor.textColor])
        #expect(colors(of: "@@ -1,5", in: rendered) == [NSColor.secondaryLabelColor])
    }

    @Test func aLargeFileShowsPlainFirstThenTakesItsColours() async throws {
        let view = DiffTextView.make()
        view.inlineHighlightRows = 0
        view.show(RenderedDiff(file: try greet(path: "greet.go")))
        #expect(colors(of: "func", in: view) == [NSColor.textColor])

        for _ in 0..<200 where colors(of: "func", in: view) == [NSColor.textColor] {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(colors(of: "func", in: view) == [DiffColors.syntaxKeyword])
    }

    @Test(arguments: [
        ("a.go", "// note"), ("a.js", "// note"), ("a.ts", "// note"), ("a.tsx", "// note"),
        ("Gemfile", "# note"), ("a.swift", "// note"), ("a.json", "\"note\""), ("a.yml", "# note"),
        ("a.sh", "# note"), ("a.css", "/* note */"), ("a.html", "<!-- note -->"),
        ("Dockerfile", "# note"), ("a.sql", "-- note"), ("go.mod", "// note"), ("a.py", "# note"), ("a.md", "# Note"),
        ("a.proto", "// note"),
    ])
    func everySupportedLanguageHighlights(path: String, line: String) throws {
        #expect(SyntaxLanguage(path: path) != nil)
        let file = try #require(Diff(parsing: """
        diff --git a/\(path) b/\(path)
        --- a/\(path)
        +++ b/\(path)
        @@ -0,0 +1 @@
        +\(line)

        """).files.first)
        #expect(colors(of: line, in: showing(file)) != [NSColor.textColor])
    }

    @Test(arguments: ["Dockerfile.prod", "deploy/Containerfile", "build.dockerfile"])
    func recognisesDockerfilesByName(path: String) throws {
        let file = try #require(Diff(parsing: """
        diff --git a/\(path) b/\(path)
        --- a/\(path)
        +++ b/\(path)
        @@ -0,0 +1 @@
        +FROM golang

        """).files.first)
        #expect(colors(of: "FROM", in: showing(file)) == [DiffColors.syntaxKeyword])
    }

    @Test func picksALanguageByFileNameBeforeExtension() {
        #expect(SyntaxLanguage(path: "deploy/Dockerfile") == SyntaxLanguage(path: "a.dockerfile"))
        #expect(SyntaxLanguage(path: "go.mod") != nil)
        #expect(SyntaxLanguage(path: "go.mod") != SyntaxLanguage(path: "a.go"))
        // Linguist knows Makefiles, but there's no grammar to colour them with.
        #expect(SyntaxLanguage(path: "Makefile") == nil)
    }

    @Test func picksALanguageByTheLongestExtension() {
        #expect(SyntaxLanguage(path: "db/schema.yml.mysql") == SyntaxLanguage(path: "a.yml"))
        #expect(SyntaxLanguage(path: "a.mysql") == SyntaxLanguage(path: "a.sql"))
        #expect(SyntaxLanguage(path: "build.gradle.kts") == SyntaxLanguage(path: "a.kt"))
    }

    @Test func colorsAProtocolBufferFile() throws {
        let file = try #require(Diff(parsing: """
        diff --git a/user.proto b/user.proto
        --- a/user.proto
        +++ b/user.proto
        @@ -0,0 +1,10 @@
        +syntax = "proto3";
        +
        +// Users of the service.
        +package x;
        +option go_package = "example.com/x";
        +
        +message Foo {
        +  string name = 1;
        +  repeated int32 ids = 2;
        +}

        """).files.first)
        let rendered = showing(file)

        for keyword in ["syntax", "package", "option", "message", "repeated"] {
            #expect(colors(of: keyword, in: rendered) == [DiffColors.syntaxKeyword], "\(keyword)")
        }
        #expect(colors(of: "\"proto3\"", in: rendered) == [DiffColors.syntaxString])
        #expect(colors(of: "\"example.com/x\"", in: rendered) == [DiffColors.syntaxString])
        #expect(colors(of: "// Users of the service.", in: rendered) == [DiffColors.syntaxComment])
        #expect(colors(of: "Foo", in: rendered) == [DiffColors.syntaxEntity])
        // Scalar types are built in, so they take the keyword colour, as Go's do.
        #expect(colors(of: "string name", in: rendered, length: 6) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "int32", in: rendered) == [DiffColors.syntaxKeyword])
        #expect(colors(of: "name =", in: rendered, length: 4) == [DiffColors.syntaxConstant])
        #expect(colors(of: "1;", in: rendered, length: 1) == [DiffColors.syntaxConstant])
        #expect(colors(of: "2;", in: rendered, length: 1) == [DiffColors.syntaxConstant])
    }

    @Test func leavesAFileInAnUnknownLanguageUncoloured() throws {
        let plain = try showing(greet(path: "greet.unknown"))

        for needle in ["func", "// Greet says hello.", "\"hello\"", "\"hi\""] {
            #expect(colors(of: needle, in: plain) == [NSColor.textColor])
        }
    }
}

private func greet(path: String) throws -> FileDiff {
    try #require(Diff(parsing: """
    diff --git a/\(path) b/\(path)
    --- a/\(path)
    +++ b/\(path)
    @@ -1,5 +1,5 @@
     package main

    -// Greet says hi.
    +// Greet says hello.
     func Greet() string {
    -\treturn "hi"
    +\treturn "hello"

    """).files.first)
}

@MainActor
private func showing(_ file: FileDiff) -> DiffTextView {
    let view = DiffTextView.make()
    view.show(RenderedDiff(file: file))
    return view
}

/// The distinct colours the view draws across the first occurrence of `needle` (or its first `length` characters).
@MainActor
private func colors(of needle: String, in view: DiffTextView, length: Int? = nil) -> [NSColor] {
    guard let layoutManager = view.layoutManager, let storage = view.textStorage else { return [] }
    let found = (storage.string as NSString).range(of: needle)
    var seen: [NSColor] = []
    for index in found.location..<(found.location + (length ?? found.length)) {
        let drawn = layoutManager.temporaryAttribute(.foregroundColor, atCharacterIndex: index, effectiveRange: nil)
            ?? storage.attribute(.foregroundColor, at: index, effectiveRange: nil)
        if let color = drawn as? NSColor, !seen.contains(color) { seen.append(color) }
    }
    return seen
}
