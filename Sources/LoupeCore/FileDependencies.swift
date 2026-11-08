import Foundation
import os
import SwiftTreeSitter

/// Which changed files use which, read from their imports, for listing them in dependency order.
/// Only the changed files are read, with the few files that say how their imports resolve, so
/// a file is only ever found to use another changed file.
public enum FileDependencies {
    /// Files larger than this aren't read, and so use nothing.
    public static let largestFile = 1 << 20

    /// The files to read, at the changes' head, to find the dependencies among `paths`: those of
    /// them in a language whose imports are understood, and the files that may say how those
    /// resolve. Some may not exist.
    public static func filesToRead(among paths: [String]) -> [String] {
        var wanted: [String] = []
        var seen = Set<String>()
        for language in languages {
            for path in language.filesToRead(among: paths) where seen.insert(path).inserted { wanted.append(path) }
        }
        return wanted
    }

    /// The files among `paths` each one uses, from `contents`, the text of those `filesToRead`
    /// named that exist.
    public static func find(among paths: [String], contents: [String: String]) -> [String: Set<String>] {
        var dependencies: [String: Set<String>] = [:]
        for language in languages {
            for (path, used) in language.dependencies(among: paths, contents: contents) {
                dependencies[path, default: []].formUnion(used)
            }
        }
        return dependencies
    }

    private static let languages: [any DependencyLanguage] = [GoDependencies(), ScriptDependencies(), TerraformDependencies()]
}

/// One language's imports: which files are needed to read them, and which changed files they name.
protocol DependencyLanguage: Sendable {
    func filesToRead(among paths: [String]) -> [String]
    func dependencies(among paths: [String], contents: [String: String]) -> [String: Set<String>]
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
