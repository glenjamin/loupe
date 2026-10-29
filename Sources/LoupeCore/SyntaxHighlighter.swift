import AppKit
import CodeEditLanguages
import CodeLanguages_Container
import os
import SwiftTreeSitter
import TreeSitterGoTemplate
import TreeSitterGraphQL
import TreeSitterHCL
import TreeSitterMake
import TreeSitterProto
import TreeSitterSCSS

/// A grammar the diff view can highlight, chosen as GitHub does: the path's Linguist language,
/// then the CodeEditLanguages or vendored grammar for it. The first of an ambiguous extension's languages
/// that has a grammar wins.
public struct SyntaxLanguage: Sendable, Hashable {
    public let rawValue: String

    public init?(path: String) {
        var languages = Linguist.languages.languages(forPath: path)
        // A suffix Linguist doesn't know, such as a deployment's (`database.yml.ci`), is passed over
        // for the extension before it. Only for colouring: GitHub goes by the last extension.
        let stem = (path as NSString).deletingPathExtension
        if languages.isEmpty, stem != path { languages = Linguist.languages.languages(forPath: stem) }
        guard let grammar = languages.lazy.compactMap(Self.grammar(forLinguistName:)).first else { return nil }
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
        /// The line git names as enclosing the hunk, such as the declaration it starts inside,
        /// whose fields would otherwise parse as statements. It's parsed but not shown.
        var context: String?
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
    /// A side with an enclosing line is parsed led by it, which puts a hunk that starts inside a
    /// declaration back in it, if that colours at least as much of the side's first lines as
    /// parsing them alone: the line misleads when the declaration closed before the hunk.
    public func runs() -> [SyntaxRun] {
        guard let grammar = Grammar.load(language) else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(grammar.language)) != nil else { return [] }
        var runs: [SyntaxRun] = []
        for side in sides where !side.lines.isEmpty {
            guard let context = side.context else {
                runs += side.highlight(side.text, parsedBy: parser, grammar: grammar)
                continue
            }
            let opening = side.opening
            let led = opening.highlight(context + "\n" + opening.text, parsedBy: parser, grammar: grammar)
            let plain = opening.highlight(opening.text, parsedBy: parser, grammar: grammar)
            let leads = coverage(of: led) >= coverage(of: plain)
            if opening.utf16Count == side.utf16Count {
                runs += leads ? led : plain
            } else {
                runs += side.highlight(leads ? context + "\n" + side.text : side.text, parsedBy: parser, grammar: grammar)
            }
        }
        return runs
    }
}

extension SyntaxLanguage {
    /// The grammar for a Linguist language: the one of the same name, or as listed here where
    /// the names differ or several Linguist languages share one grammar.
    static func grammar(forLinguistName name: String) -> String? {
        if let vendored = VendoredGrammar(linguistName: name) { return vendored.rawValue }
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

    /// Loaded grammars, and nil for those that couldn't be, so a failure is logged once.
    private static let cache = OSAllocatedUnfairLock<[SyntaxLanguage: Grammar?]>(initialState: [:])

    /// The grammar and its compiled highlights query, compiled once per language. CodeEditLanguages'
    /// own `CodeLanguage` isn't used, as making one reaches its `Bundle.module`, which stops the
    /// process when run from the app bundle.
    static func load(_ syntax: SyntaxLanguage) -> Grammar? {
        if let cached = cache.withLock({ $0[syntax] }) { return cached }
        let grammar = compile(syntax)
        if grammar == nil { logger.error("No grammar or highlights query for \(syntax.rawValue, privacy: .public)") }
        cache.withLock { $0[syntax] = .some(grammar) }
        return grammar
    }

    private static func compile(_ syntax: SyntaxLanguage) -> Grammar? {
        if let vendored = VendoredGrammar(rawValue: syntax.rawValue) {
            return compile(vendored.tsLanguage, queries: vendored.highlightQueries, laterPatternsWin: true)
        }
        guard let id = TreeSitterLanguage(rawValue: syntax.rawValue) else { return nil }
        let urls = highlightQueries(id).map { codeEditLanguagesQuery(folder: $0.folder, file: $0.file) }
        return compile(id.tsLanguage, queries: urls, laterPatternsWin: id != .go)
    }

    private static func compile(_ parser: OpaquePointer?, queries urls: [URL?], laterPatternsWin: Bool) -> Grammar? {
        guard let parser else { return nil }
        let language = Language(language: parser)
        let source = urls.compactMap { $0.flatMap { try? Data(contentsOf: $0) } }
        guard !source.isEmpty, source.count == urls.count,
              let query = try? Query(language: language, data: source.reduce(Data()) { $0 + $1 + Data("\n".utf8) })
        else { return nil }
        return Grammar(language: language, query: query, laterPatternsWin: laterPatternsWin)
    }

    /// Query files, composed as each grammar's tree-sitter.json does: TypeScript builds on
    /// JavaScript's, and JSX patterns come with JavaScript and TSX.
    private static func highlightQueries(_ id: TreeSitterLanguage) -> [(folder: String, file: String)] {
        let js = { (files: [String]) in files.map { (folder: "javascript", file: $0) } }
        return switch id {
        case .javascript, .jsx: js(["highlights", "highlights-jsx", "highlights-params"])
        case .typescript: [("typescript", "highlights")] + js(["highlights"])
        case .tsx: [("typescript", "highlights")] + js(["highlights-jsx", "highlights"])
        case .goMod: [("go-mod", "highlights")]
        case .cSharp: [("c-sharp", "highlights")]
        case .markdownInline: [("markdown-inline", "highlights")]
        case .ocamlInterface: [("ocaml", "highlights")]
        default: [(id.rawValue, "highlights")]
        }
    }
}

private extension TreeSitterLanguage {
    /// The parser from CodeEditLanguages' prebuilt framework.
    var tsLanguage: OpaquePointer? {
        switch self {
        case .agda: tree_sitter_agda()
        case .bash: tree_sitter_bash()
        case .c: tree_sitter_c()
        case .cpp: tree_sitter_cpp()
        case .cSharp: tree_sitter_c_sharp()
        case .css: tree_sitter_css()
        case .dart: tree_sitter_dart()
        case .dockerfile: tree_sitter_dockerfile()
        case .elixir: tree_sitter_elixir()
        case .go: tree_sitter_go()
        case .goMod: tree_sitter_gomod()
        case .haskell: tree_sitter_haskell()
        case .html: tree_sitter_html()
        case .java: tree_sitter_java()
        case .javascript, .jsx: tree_sitter_javascript()
        case .jsdoc: tree_sitter_jsdoc()
        case .json: tree_sitter_json()
        case .julia: tree_sitter_julia()
        case .kotlin: tree_sitter_kotlin()
        case .lua: tree_sitter_lua()
        case .markdown: tree_sitter_markdown()
        case .markdownInline: tree_sitter_markdown_inline()
        case .objc: tree_sitter_objc()
        case .ocaml: tree_sitter_ocaml()
        case .ocamlInterface: tree_sitter_ocaml_interface()
        case .perl: tree_sitter_perl()
        case .php: tree_sitter_php()
        case .python: tree_sitter_python()
        case .regex: tree_sitter_regex()
        case .ruby: tree_sitter_ruby()
        case .rust: tree_sitter_rust()
        case .scala: tree_sitter_scala()
        case .sql: tree_sitter_sql()
        case .swift: tree_sitter_swift()
        case .toml: tree_sitter_toml()
        case .tsx: tree_sitter_tsx()
        case .typescript: tree_sitter_typescript()
        case .verilog: tree_sitter_verilog()
        case .yaml: tree_sitter_yaml()
        case .zig: tree_sitter_zig()
        case .plainText: nil
        }
    }
}

/// Grammars CodeEditLanguages lacks, each vendored as a target of its own with a highlights
/// query in its resource bundle.
private enum VendoredGrammar: String {
    case proto
    case hcl
    case graphql
    case scss
    case make
    case goTemplate

    init?(linguistName: String) {
        switch linguistName {
        case "Protocol Buffer": self = .proto
        case "HCL": self = .hcl
        case "GraphQL": self = .graphql
        case "SCSS": self = .scss
        case "Makefile": self = .make
        case "Go Template": self = .goTemplate
        default: return nil
        }
    }

    var tsLanguage: OpaquePointer? {
        switch self {
        case .proto: tree_sitter_proto()
        case .hcl: tree_sitter_hcl()
        case .graphql: tree_sitter_graphql()
        case .scss: tree_sitter_scss()
        case .make: tree_sitter_make()
        case .goTemplate: tree_sitter_gotmpl()
        }
    }

    var bundle: String {
        switch self {
        case .proto: "Loupe_TreeSitterProto"
        case .hcl: "Loupe_TreeSitterHCL"
        case .graphql: "Loupe_TreeSitterGraphQL"
        case .scss: "Loupe_TreeSitterSCSS"
        case .make: "Loupe_TreeSitterMake"
        case .goTemplate: "Loupe_TreeSitterGoTemplate"
        }
    }

    /// The grammar's highlights query, with that of the grammar it extends beneath it: SCSS's
    /// query covers only what SCSS adds to CSS, as editors compose it.
    var highlightQueries: [URL?] {
        let own = bundledResource("queries/highlights.scm", in: bundle)
        return switch self {
        case .scss: [codeEditLanguagesQuery(folder: "css", file: "highlights"), own]
        case .proto, .hcl, .graphql, .make, .goTemplate: [own]
        }
    }
}

private let logger = Logger(subsystem: "com.glenmailer.Loupe", category: "syntax")

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

/// How many characters of code some runs colour, each counted once however many runs cover it.
private func coverage(of runs: [SyntaxRun]) -> Int {
    var covered = IndexSet()
    for run in runs { covered.insert(integersIn: run.range.location..<NSMaxRange(run.range)) }
    return covered.count
}

private extension SyntaxPlan.Side {
    /// The colours for this side's lines from parsing `text`, which ends with the side's own.
    func highlight(_ text: String, parsedBy parser: Parser, grammar: Grammar) -> [SyntaxRun] {
        guard let tree = parser.parse(text) else { return [] }
        let codeStart = text.utf16.count - utf16Count
        var runs: [SyntaxRun] = []
        for capture in highlightCaptures(grammar.query, in: tree, text: text, laterPatternsWin: grammar.laterPatternsWin) {
            let range = NSRange(location: capture.range.location - codeStart, length: capture.range.length)
            map(range, through: lines) { runs.append(SyntaxRun(range: $0, style: capture.style)) }
        }
        return runs
    }

    /// The side's first lines, enough to tell whether its enclosing line helps, so a long
    /// side is parsed in full only once.
    var opening: Self {
        var end = text.startIndex
        for _ in 0..<20 {
            guard let newline = text.utf8[end...].firstIndex(of: UInt8(ascii: "\n")) else { return self }
            end = text.utf8.index(after: newline)
        }
        let first = String(text[..<end])
        let length = first.utf16.count
        return Self(context: context, text: first, utf16Count: length, lines: lines.filter { $0.source < length })
    }
}

private func codeEditLanguagesQuery(folder: String, file: String) -> URL? {
    bundledResource("Resources/tree-sitter-\(folder)/\(file).scm", in: "CodeEditLanguages_CodeEditLanguages")
}
