import AppKit
import os
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterCSS
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterRuby
import TreeSitterSwift
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// A grammar the diff view can highlight, chosen from a file's name.
public enum SyntaxLanguage: String, Sendable, CaseIterable {
    case go, javascript, typescript, tsx, ruby, swift, json, yaml, bash, css, html

    public init?(path: String) {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if let language = Self.byName[name] {
            self = language
            return
        }
        let ext = name.split(separator: ".").last.map { $0.lowercased() } ?? ""
        guard name.contains("."), let language = Self.byExtension[ext] else { return nil }
        self = language
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
            let captures = highlightCaptures(grammar.query, in: tree, text: side.text, laterPatternsWin: language.laterPatternsWin)
            for capture in captures {
                map(capture.range, through: side.lines) { runs.append(SyntaxRun(range: $0, style: capture.style)) }
            }
        }
        return runs
    }
}

extension SyntaxLanguage {
    static let byExtension: [String: SyntaxLanguage] = [
        "go": .go,
        "js": .javascript, "mjs": .javascript, "cjs": .javascript, "jsx": .javascript,
        "ts": .typescript, "mts": .typescript, "cts": .typescript,
        "tsx": .tsx,
        "rb": .ruby, "rake": .ruby, "gemspec": .ruby, "ru": .ruby,
        "swift": .swift,
        "json": .json,
        "yml": .yaml, "yaml": .yaml,
        "sh": .bash, "bash": .bash, "zsh": .bash,
        "css": .css,
        "html": .html, "htm": .html,
    ]

    static let byName: [String: SyntaxLanguage] = [
        "Gemfile": .ruby, "Rakefile": .ruby, "Podfile": .ruby, "Brewfile": .ruby, "Vagrantfile": .ruby, "Guardfile": .ruby,
        ".bashrc": .bash, ".bash_profile": .bash, ".zshrc": .bash, ".profile": .bash, ".envrc": .bash,
    ]
}

/// Maps a tree-sitter capture name onto a colour. Plain identifiers (`variable`) and punctuation
/// stay the default text colour, as on GitHub; unknown names leave whatever encloses them.
func syntaxStyle(forCapture name: String) -> SyntaxStyle? {
    let parts = name.split(separator: ".")
    switch parts.first {
    case "keyword", "operator", "conditional", "repeat", "include", "exception":
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
    case "number", "float", "boolean", "constant", "property", "attribute":
        return .constant
    case "variable":
        switch parts.dropFirst().first {
        case "parameter": return .variable
        case "builtin": return .constant
        default: return nil
        }
    case "tag":
        return .tag
    default:
        return nil
    }
}

private struct Grammar: Sendable {
    let language: Language
    let query: Query

    private static let cache = OSAllocatedUnfairLock<[SyntaxLanguage: Grammar]>(initialState: [:])

    /// The grammar and its compiled highlights query, compiled once per language.
    static func load(_ syntax: SyntaxLanguage) -> Grammar? {
        if let cached = cache.withLock({ $0[syntax] }) { return cached }
        let language = Language(language: syntax.tsLanguage)
        let source = syntax.highlightQueries.compactMap { bundle, file in
            queryURL(bundle: bundle, file: file).flatMap { try? Data(contentsOf: $0) }
        }
        guard source.count == syntax.highlightQueries.count,
              let query = try? Query(language: language, data: source.reduce(Data()) { $0 + $1 + Data("\n".utf8) })
        else { return nil }
        let grammar = Grammar(language: language, query: query)
        cache.withLock { $0[syntax] = grammar }
        return grammar
    }
}

private extension SyntaxLanguage {
    var tsLanguage: OpaquePointer {
        switch self {
        case .go: tree_sitter_go()
        case .javascript: tree_sitter_javascript()
        case .typescript: tree_sitter_typescript()
        case .tsx: tree_sitter_tsx()
        case .ruby: tree_sitter_ruby()
        case .swift: tree_sitter_swift()
        case .json: tree_sitter_json()
        case .yaml: tree_sitter_yaml()
        case .bash: tree_sitter_bash()
        case .css: tree_sitter_css()
        case .html: tree_sitter_html()
        }
    }

    /// Where several patterns capture one node, tree-sitter's highlighter takes the last, and the
    /// queries list generic patterns first. Go's still lists them last, for the older first-wins rule.
    var laterPatternsWin: Bool { self != .go }

    /// Query files, composed as each grammar's tree-sitter.json does: TypeScript builds on JavaScript's.
    var highlightQueries: [(bundle: String, file: String)] {
        let js = "TreeSitterJavaScript_TreeSitterJavaScript"
        switch self {
        case .javascript: return [(js, "highlights.scm"), (js, "highlights-jsx.scm"), (js, "highlights-params.scm")]
        case .typescript: return [("TreeSitterTypeScript_TreeSitterTypeScript", "highlights.scm"), (js, "highlights.scm")]
        case .tsx: return [("TreeSitterTypeScript_TreeSitterTSX", "highlights.scm"), (js, "highlights-jsx.scm"), (js, "highlights.scm")]
        default:
            let name = switch self {
            case .go: "Go"
            case .ruby: "Ruby"
            case .swift: "Swift"
            case .json: "JSON"
            case .yaml: "YAML"
            case .bash: "Bash"
            case .css: "CSS"
            default: "HTML"
            }
            return [("TreeSitter\(name)_TreeSitter\(name)", "highlights.scm")]
        }
    }
}

private final class BundleToken {}

/// SwiftPM puts each grammar's queries in a resource bundle: beside the executable for
/// `swift run` and tests, in Contents/Resources inside the app.
private func queryURL(bundle: String, file: String) -> URL? {
    let containers = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()]
    for container in containers.compactMap({ $0 }) {
        for queries in ["queries", "Contents/Resources/queries"] {
            let url = container.appending(path: "\(bundle).bundle/\(queries)/\(file)")
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
    }
    return nil
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
