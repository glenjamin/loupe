import AppKit
import CodeEditLanguages
import os
import SwiftTreeSitter

/// A grammar the diff view can highlight, chosen as GitHub does: the path's Linguist language,
/// then the CodeEditLanguages grammar for it. The first of an ambiguous extension's languages
/// that has a grammar wins.
public struct SyntaxLanguage: Sendable, Hashable {
    public let rawValue: String

    public init?(path: String) {
        guard let grammar = Linguist.languages.languages(forPath: path).lazy.compactMap(Self.grammar(forLinguistName:)).first else { return nil }
        rawValue = grammar
    }
}

/// How a highlighted span is coloured, following GitHub's Primer syntax palette.
public enum SyntaxStyle: Sendable {
    case keyword, string, comment, entity, constant, variable, tag

    public var color: NSColor {
        switch self {
        case .keyword: DiffColors.syntaxKeyword
        case .string: DiffColors.syntaxString
        case .comment: DiffColors.syntaxComment
        case .entity: DiffColors.syntaxEntity
        case .constant: DiffColors.syntaxConstant
        case .variable: DiffColors.syntaxVariable
        case .tag: DiffColors.syntaxTag
        }
    }
}

/// A coloured span of the rendered diff, in its attributed string's UTF-16 offsets. Runs come
/// outermost first, so applying them in order lets a nested span (an escape in a string) win.
public struct SyntaxRun: Sendable, Equatable {
    public var range: NSRange
    public var style: SyntaxStyle
}

/// The code of one file's hunks, ready to parse: each hunk's new side (context and additions)
/// and old side (context and deletions), with where each line's code sits in the rendered diff.
/// Sendable so large files can be highlighted off the main thread.
public struct SyntaxPlan: Sendable {
    struct Line: Sendable {
        var source: Int
        var target: Int
        var length: Int
    }

    struct Side: Sendable {
        var text = ""
        var utf16Count = 0
        /// Lines to colour from this side, ascending by source offset.
        var lines: [Line] = []

        mutating func append(_ code: String, mappedTo target: Int?, length: Int) {
            if let target { lines.append(Line(source: utf16Count, target: target, length: length)) }
            text += code
            text += "\n"
            utf16Count += code.utf16.count + 1
        }
    }

    public let language: SyntaxLanguage
    var sides: [Side] = []

    init(_ language: SyntaxLanguage) {
        self.language = language
    }

    /// Parses each side and maps the highlight query's captures onto the rendered rows.
    /// Snippets that don't parse cleanly still highlight, through tree-sitter's error recovery.
    public func runs() -> [SyntaxRun] {
        guard let grammar = Grammar.load(language) else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(grammar.language)) != nil else { return [] }
        var runs: [SyntaxRun] = []
        for side in sides where !side.lines.isEmpty {
            guard let tree = parser.parse(side.text) else { continue }
            let captures = highlightCaptures(grammar.query, in: tree, text: side.text, laterPatternsWin: grammar.laterPatternsWin)
            for capture in captures {
                map(capture.range, through: side.lines) { runs.append(SyntaxRun(range: $0, style: capture.style)) }
            }
        }
        return runs
    }
}

extension SyntaxLanguage {
    /// The grammar for a Linguist language: the one of the same name, or as listed here where
    /// the names differ or several Linguist languages share one grammar.
    static func grammar(forLinguistName name: String) -> String? {
        if let shared = sharedGrammars[name] { return shared.rawValue }
        guard let grammar = TreeSitterLanguage(rawValue: name.lowercased()), grammar != .plainText else { return nil }
        return grammar.rawValue
    }

    private static var sharedGrammars: [String: TreeSitterLanguage] {
        [
            "Shell": .bash,
            "C++": .cpp,
            "C#": .cSharp,
            "Objective-C": .objc,
            "Go Module": .goMod,
            "JSON with Comments": .json,
            "Gradle Kotlin DSL": .kotlin,
        ]
    }
}

/// Maps a tree-sitter capture name onto a colour. Plain identifiers (`variable`) and punctuation
/// stay the default text colour, as on GitHub; unknown names leave whatever encloses them.
func syntaxStyle(forCapture name: String) -> SyntaxStyle? {
    let parts = name.split(separator: ".")
    switch parts.first {
    case "keyword", "operator", "conditional", "repeat", "include", "exception", "storageclass",
         "import", "charset", "media", "keyframes", "supports":
        return .keyword
    case "string", "character":
        if parts.dropFirst().first == "escape" { return nil }
        return parts.last == "key" ? .constant : .string
    case "comment":
        return .comment
    case "function", "method", "constructor":
        return .entity
    case "type":
        return parts.dropFirst().first == "builtin" ? .keyword : .entity
    case "number", "float", "boolean", "constant", "property", "field", "attribute":
        return .constant
    case "parameter":
        return .variable
    case "variable":
        switch parts.dropFirst().first {
        case "parameter": return .variable
        case "builtin": return .constant
        default: return nil
        }
    case "tag":
        return .tag
    case "text":
        return parts.dropFirst().first == "title" ? .constant : nil
    default:
        return nil
    }
}

private struct Grammar: Sendable {
    let language: Language
    let query: Query
    /// Where several patterns capture one node, tree-sitter's highlighter takes the last, and the
    /// queries list generic patterns first. Go's still lists them last, for the older first-wins rule.
    let laterPatternsWin: Bool

    private static let cache = OSAllocatedUnfairLock<[SyntaxLanguage: Grammar]>(initialState: [:])

    /// The grammar and its compiled highlights query, compiled once per language.
    static func load(_ syntax: SyntaxLanguage) -> Grammar? {
        if let cached = cache.withLock({ $0[syntax] }) { return cached }
        guard let id = TreeSitterLanguage(rawValue: syntax.rawValue),
              let code = CodeLanguage.allLanguages.first(where: { $0.id == id }),
              let language = code.language,
              let urls = highlightQueries(code)
        else { return nil }
        let source = urls.compactMap { try? Data(contentsOf: $0) }
        guard source.count == urls.count,
              let query = try? Query(language: language, data: source.reduce(Data()) { $0 + $1 + Data("\n".utf8) })
        else { return nil }
        let grammar = Grammar(language: language, query: query, laterPatternsWin: id != .go)
        cache.withLock { $0[syntax] = grammar }
        return grammar
    }

    /// Query files, composed as each grammar's tree-sitter.json does: TypeScript builds on
    /// JavaScript's, and JSX patterns come with JavaScript and TSX.
    private static func highlightQueries(_ code: CodeLanguage) -> [URL]? {
        guard let own = code.queryURL.flatMap(readable) else { return nil }
        let js = CodeLanguage.javascript.queryURL.flatMap(readable)?.deletingLastPathComponent()
        let jsQueries = { (names: [String]) in names.compactMap { js?.appending(path: "\($0).scm") } }
        return switch code.id {
        case .javascript, .jsx: jsQueries(["highlights", "highlights-jsx", "highlights-params"])
        case .typescript: [own] + jsQueries(["highlights"])
        case .tsx: [own] + jsQueries(["highlights-jsx", "highlights"])
        default: [own]
        }
    }
}

/// CodeEditLanguages builds its query paths for Xcode's bundle layout, which nests a second
/// `Resources` folder; SwiftPM's flat bundle doesn't, so fall back to the path without it.
private func readable(_ url: URL) -> URL? {
    if FileManager.default.isReadableFile(atPath: url.path) { return url }
    let bundleResources = url.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let flat = url.pathComponents.suffix(2).reduce(bundleResources) { $0.appending(path: $1) }
    return FileManager.default.isReadableFile(atPath: flat.path) ? flat : nil
}

/// Captures to colour, outermost first so nested ones paint over them, with one pattern's
/// capture chosen per node.
private func highlightCaptures(_ query: Query, in tree: MutableTree, text: String, laterPatternsWin: Bool) -> [(range: NSRange, style: SyntaxStyle)] {
    var best: [NSRange: (pattern: Int, style: SyntaxStyle?)] = [:]
    let matches = query.execute(in: tree).resolve(with: Predicate.Context(string: text))
    for match in matches {
        for capture in match.captures {
            let range = capture.range
            guard range.length > 0, let name = capture.name else { continue }
            if let existing = best[range], (existing.pattern < capture.patternIndex) != laterPatternsWin { continue }
            best[range] = (capture.patternIndex, syntaxStyle(forCapture: name))
        }
    }
    return best
        .compactMap { range, value in value.style.map { (range, $0) } }
        .sorted { $0.range.location != $1.range.location ? $0.range.location < $1.range.location : $0.range.length > $1.range.length }
}

/// Splits a span of a side's text into the pieces that fall on mapped lines, in rendered offsets.
private func map(_ range: NSRange, through lines: [SyntaxPlan.Line], _ emit: (NSRange) -> Void) {
    var low = 0
    var high = lines.count
    while low < high {
        let mid = (low + high) / 2
        if lines[mid].source + lines[mid].length <= range.location { low = mid + 1 } else { high = mid }
    }
    let end = NSMaxRange(range)
    var index = low
    while index < lines.count, lines[index].source < end {
        let line = lines[index]
        let start = max(range.location, line.source)
        let stop = min(end, line.source + line.length)
        if stop > start { emit(NSRange(location: line.target + start - line.source, length: stop - start)) }
        index += 1
    }
}
