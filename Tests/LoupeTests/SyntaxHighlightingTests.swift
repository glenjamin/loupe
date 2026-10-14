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
