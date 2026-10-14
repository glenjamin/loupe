/// A parsed unified diff, as produced by `git diff`.
public struct Diff: Sendable {
    public var files: [FileDiff]

    public init(files: [FileDiff]) {
        self.files = files
    }

    public init(parsing text: String) {
        self.files = DiffParser.parse(text)
    }
}

public struct FileDiff: Sendable, Identifiable {
    public enum Change: Sendable, Equatable {
        case added, deleted, modified
        case renamed(from: String, similarity: Int)
        case copied(from: String, similarity: Int)
    }

    /// The path on the new side, or the old path for a deletion.
    public var path: String
    public var change: Change
    public var isBinary: Bool
    public var hunks: [Hunk]

    public var id: String { path }

    public init(path: String, change: Change, isBinary: Bool, hunks: [Hunk]) {
        self.path = path
        self.change = change
        self.isBinary = isBinary
        self.hunks = hunks
    }

    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count(where: \.isAddition) } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count(where: \.isDeletion) } }
}

public struct Hunk: Sendable {
    /// The full `@@ -a,b +c,d @@ section` line.
    public var header: String
    public var oldStart: Int
    public var newStart: Int
    public var lines: [DiffLine]

    public init(header: String, oldStart: Int, newStart: Int, lines: [DiffLine]) {
        self.header = header
        self.oldStart = oldStart
        self.newStart = newStart
        self.lines = lines
    }
}

public struct DiffLine: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case context(old: Int, new: Int)
        case addition(new: Int)
        case deletion(old: Int)
    }

    public var kind: Kind
    public var text: String
    /// Set when git reported "\ No newline at end of file" for this line.
    public var missingNewline: Bool

    public init(kind: Kind, text: String, missingNewline: Bool = false) {
        self.kind = kind
        self.text = text
        self.missingNewline = missingNewline
    }

    public var oldLine: Int? {
        switch kind {
        case .context(let old, _), .deletion(let old): old
        case .addition: nil
        }
    }

    public var newLine: Int? {
        switch kind {
        case .context(_, let new), .addition(let new): new
        case .deletion: nil
        }
    }

    public var isAddition: Bool { if case .addition = kind { true } else { false } }
    public var isDeletion: Bool { if case .deletion = kind { true } else { false } }
}

/// Splits files into those to review and those hidden by default (vendored code, lockfiles).
public struct PathFilter: Sendable {
    public var excludedPrefixes: [String]
    public var excludedNames: Set<String>

    public static let `default` = PathFilter(
        excludedPrefixes: ["vendor/", "node_modules/"],
        excludedNames: ["go.sum", "package-lock.json", "yarn.lock", "pnpm-lock.yaml"]
    )

    public init(excludedPrefixes: [String], excludedNames: Set<String>) {
        self.excludedPrefixes = excludedPrefixes
        self.excludedNames = excludedNames
    }

    public func excludes(_ path: String) -> Bool {
        if excludedPrefixes.contains(where: { path.hasPrefix($0) || path.contains("/" + $0) }) { return true }
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return excludedNames.contains(name)
    }

    public func partition(_ files: [FileDiff]) -> (included: [FileDiff], excluded: [FileDiff]) {
        var included: [FileDiff] = []
        var excluded: [FileDiff] = []
        for file in files {
            if excludes(file.path) { excluded.append(file) } else { included.append(file) }
        }
        return (included, excluded)
    }
}
