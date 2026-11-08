import Foundation

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

    private static let languages: [any DependencyLanguage] = []
}

/// One language's imports: which files are needed to read them, and which changed files they name.
protocol DependencyLanguage: Sendable {
    func filesToRead(among paths: [String]) -> [String]
    func dependencies(among paths: [String], contents: [String: String]) -> [String: Set<String>]
}
