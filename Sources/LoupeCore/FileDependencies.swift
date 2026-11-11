import Foundation
import LoupeModel
import os
import SwiftTreeSitter

/// Which changed files use which, read from their imports, for listing them in dependency order.
/// Only the changed files are read, with the few files that say how their imports resolve, so
/// a file is only ever found to use another changed file.
public enum FileDependencies {
    /// Files larger than this aren't read, and so use nothing.
    public static let largestFile = 1 << 20

    /// The files to read, at the changes' head, to find the links among `paths`: those of them
    /// a rule reads, and the files that may say how their imports resolve. Some may not exist.
    public static func filesToRead(among paths: [String]) -> [String] {
        var wanted: [String] = []
        var seen = Set<String>()
        for rule in rules {
            for path in rule.filesToRead(among: paths) where seen.insert(path).inserted { wanted.append(path) }
        }
        return wanted
    }

    /// The directories whose files to list, at the changes' head, to find the links among `paths`.
    public static func directoriesToList(among paths: [String]) -> [String] {
        var seen = Set<String>()
        return rules.flatMap { $0.directoriesToList(among: paths) }.filter { seen.insert($0).inserted }
    }

    /// The links among `paths`, from `contents`, the text of those `filesToRead` named that exist,
    /// and `listings`, the names of the files in each of `directoriesToList`.
    public static func find(among paths: [String], contents: [String: String], listings: [String: [String]] = [:]) -> [DependencyLink] {
        var seen = Set<DependencyLink>()
        let links = rules.flatMap { $0.links(among: paths, contents: contents, listings: listings) }.filter { $0.from != $0.to && seen.insert($0).inserted }
        return links + testsOfWhatTheyUse(links, among: paths)
    }

    private static let rules: [any DependencyRule] = [
        GoDependencies(), ScriptDependencies(), TerraformDependencies(), SwiftDependencies(), StylesheetDependencies(), RubyDependencies(),
        RailsConventions(), CompanionNames(), Readmes(),
    ]

    /// A test named for no changed file tests the file its code uses most, so it follows that file
    /// as a test named for it would. A tie goes to a file using the others tied, as the test
    /// reaches them through it, then to the first by path. Other tests, and files it only names
    /// the path of, such as fixtures, aren't what it tests.
    private static func testsOfWhatTheyUse(_ links: [DependencyLink], among paths: [String]) -> [DependencyLink] {
        let tests = Set(paths.filter { TestNaming($0)?.reason == .tests })
        let named = Set(links.filter { $0.reason == .tests }.map(\.from))
        let ordering: Set<DependencyLink.Reason> = [.imports, .names, .convention]
        var uses: [String: [String: Int]] = [:]
        for link in links where tests.contains(link.from) && !named.contains(link.from) && !tests.contains(link.to) && ordering.contains(link.reason) {
            uses[link.from, default: [:]][link.to, default: 0] += 1
        }
        let used = links.filter { ordering.contains($0.reason) }.reduce(into: [String: Set<String>]()) { $0[$1.from, default: []].insert($1.to) }
        return uses.compactMap { test, counts in
            guard let most = counts.values.max() else { return nil }
            let tied = Set(counts.filter { $0.value == most }.keys)
            let subject = tied.min { first, second in
                let (firstUses, secondUses) = ((used[first] ?? []).intersection(tied).count, (used[second] ?? []).intersection(tied).count)
                return firstUses != secondUses ? firstUses > secondUses : first < second
            }
            return subject.map { DependencyLink(from: test, to: $0, reason: .tests) }
        }
    }
}

/// One way changed files are linked, by a language's imports or names, or by a convention:
/// which files it needs to read, and the links it finds among the changed files.
protocol DependencyRule: Sendable {
    func filesToRead(among paths: [String]) -> [String]
    /// The directories whose files it needs listed, as for how big a module is.
    func directoriesToList(among paths: [String]) -> [String]
    func links(among paths: [String], contents: [String: String]) -> [DependencyLink]
    func links(among paths: [String], contents: [String: String], listings: [String: [String]]) -> [DependencyLink]
}

extension DependencyRule {
    func filesToRead(among paths: [String]) -> [String] { [] }
    func directoriesToList(among paths: [String]) -> [String] { [] }
    func links(among paths: [String], contents: [String: String], listings: [String: [String]]) -> [DependencyLink] {
        links(among: paths, contents: contents)
    }
}

/// Links as a rule finds them, each file to those it's linked to.
struct LinkCollector {
    private(set) var links: [DependencyLink] = []

    mutating func add(from path: String, to targets: some Sequence<String>, _ reason: DependencyLink.Reason) {
        for target in targets where target != path { links.append(DependencyLink(from: path, to: target, reason: reason)) }
    }
}

/// The names each scope's changed files define, such as a Go package's top-level declarations,
/// for linking the files in that scope that name them.
struct NameIndex {
    private var definers: [String: [String: Set<String>]] = [:]

    mutating func define(_ name: String, in path: String, scope: String) {
        definers[scope, default: [:]][name, default: []].insert(path)
    }

    func definers(of name: String, in scope: String) -> Set<String> {
        definers[scope]?[name] ?? []
    }
}

/// A query over one grammar, compiled once, that reads what a file's text names, such as the
/// paths it imports.
struct ImportQuery: Sendable {
    private let language: Language
    private let query: Query

    init?(_ parser: OpaquePointer?, _ source: String) {
        guard let parser else { return nil }
        language = Language(language: parser)
        guard let query = try? Query(language: language, data: Data(source.utf8)) else {
            logger.error("Couldn't compile a dependency query: \(source, privacy: .public)")
            return nil
        }
        self.query = query
    }

    /// The text of each capture in `text`, by capture name, in the order they come.
    func captures(in text: String) -> [(name: String, text: String)] {
        matches(in: text).flatMap { $0 }
    }

    /// Each match's captures in `text`, by capture name, in the order they come.
    func matches(in text: String) -> [[(name: String, text: String)]] {
        let parser = Parser()
        guard (try? parser.setLanguage(language)) != nil, let tree = parser.parse(text) else { return [] }
        let string = text as NSString
        return query.execute(in: tree).resolve(with: Predicate.Context(string: text)).map { match in
            match.captures.sorted { $0.range.location < $1.range.location }.compactMap { capture in
                capture.name.map { ($0, string.substring(with: capture.range)) }
            }
        }
    }
}

/// `transform` of each of `items`, run across the cores, in order: each file's parse is its own.
func concurrentMap<Item: Sendable, Result: Sendable>(_ items: [Item], _ transform: @Sendable (Item) -> Result) -> [Result] {
    let results = Results<Result>(count: items.count)
    DispatchQueue.concurrentPerform(iterations: items.count) { index in results[index] = transform(items[index]) }
    return results.values
}

/// Slots filled from several threads at once, each by one of them.
private final class Results<Value: Sendable>: @unchecked Sendable {
    private var slots: [Value?]
    private let lock = NSLock()

    init(count: Int) {
        slots = Array(repeating: nil, count: count)
    }

    subscript(index: Int) -> Value? {
        get { lock.withLock { slots[index] } }
        set { lock.withLock { slots[index] = newValue } }
    }

    var values: [Value] { lock.withLock { slots.compactMap { $0 } } }
}

/// The changed files a string in `path` names: as a path from its directory, or from the top.
func filesNamed(by literal: String, from path: String, among changed: Set<String>) -> [String] {
    guard !literal.isEmpty, literal.count < 300, !literal.contains("\n") else { return [] }
    let candidates = [normalisedPath(joined(directory(of: path), literal)), normalisedPath(literal)].compactMap { $0 }
    return Array(Set(candidates.filter { $0 != path && changed.contains($0) }))
}

/// `path`'s directory, empty for one at the top.
func directory(of path: String) -> String {
    (path as NSString).deletingLastPathComponent
}

/// The directories `path` is in, innermost first, ending with the top, as "".
func ancestors(of path: String) -> [String] {
    var directories: [String] = []
    var current = directory(of: path)
    while !current.isEmpty {
        directories.append(current)
        current = directory(of: current)
    }
    return directories + [""]
}

/// `name` in `directory`, as a path from the top.
func joined(_ directory: String, _ name: String) -> String {
    directory.isEmpty ? name : "\(directory)/\(name)"
}

/// `path` with its `.` and `..` components resolved, nil if it climbs out of the repo.
func normalisedPath(_ path: String) -> String? {
    var components: [Substring] = []
    for component in path.split(separator: "/") {
        switch component {
        case ".": continue
        case "..":
            guard !components.isEmpty else { return nil }
            components.removeLast()
        default: components.append(component)
        }
    }
    return components.joined(separator: "/")
}

private let logger = Logger(subsystem: "com.glenmailer.Loupe", category: "FileDependencies")
