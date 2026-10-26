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
    /// Set when the file was diffed ignoring changes to whitespace: the lines it adds and
    /// deletes counting them, which tell a file only whitespace changed in from one unchanged.
    public var countsWithWhitespace: LineTotals?

    public var id: String { path }

    public init(path: String, change: Change, isBinary: Bool, hunks: [Hunk], countsWithWhitespace: LineTotals? = nil) {
        self.path = path
        self.change = change
        self.isBinary = isBinary
        self.hunks = hunks
        self.countsWithWhitespace = countsWithWhitespace
    }

    /// The lines shown added and deleted, so hiding whitespace leaves its changes uncounted.
    public var additions: Int { hunks.reduce(0) { $0 + $1.lines.count(where: \.isAddition) } }
    public var deletions: Int { hunks.reduce(0) { $0 + $1.lines.count(where: \.isDeletion) } }

    /// Whether the file was diffed ignoring changes to whitespace.
    public var ignoresWhitespace: Bool { countsWithWhitespace != nil }

    /// Whether ignoring whitespace left none of the file's changed lines to show.
    public var isWhitespaceOnly: Bool {
        guard let countsWithWhitespace else { return false }
        return hunks.isEmpty && countsWithWhitespace.additions + countsWithWhitespace.deletions > 0
    }

    /// This file as diffed ignoring whitespace, from `ignoring`, its diff of that kind, or nil
    /// when git found nothing but whitespace changed in it. Keeps this diff's path and change, so
    /// the file list holds the same files either way.
    public func ignoringWhitespace(as ignoring: FileDiff?) -> FileDiff {
        FileDiff(path: path, change: change, isBinary: isBinary, hunks: ignoring?.hunks ?? [], countsWithWhitespace: LineTotals(additions: additions, deletions: deletions))
    }
}

/// How many lines a file's changes add and delete.
public struct LineTotals: Sendable, Equatable {
    public var additions: Int
    public var deletions: Int

    public init(additions: Int, deletions: Int) {
        self.additions = additions
        self.deletions = deletions
    }
}

/// A changed file known only by its path and what happened to it, as listed before (or
/// instead of) diffing it.
public struct ChangedFile: Sendable, Equatable, Identifiable {
    public var path: String
    public var change: FileDiff.Change
    public var additions: Int
    public var deletions: Int
    /// Git counts no lines in a binary file.
    public var isBinary: Bool

    public var id: String { path }

    public init(path: String, change: FileDiff.Change, additions: Int = 0, deletions: Int = 0, isBinary: Bool = false) {
        self.path = path
        self.change = change
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
    }

    /// The path it had before, for a rename or copy.
    public var renamedFrom: String? {
        switch change {
        case .renamed(let from, _), .copied(let from, _): from
        case .added, .deleted, .modified: nil
        }
    }
}

/// How much some changes touch: the files changed and the lines added and deleted in them. A
/// binary file counts as a file with no lines.
public struct DiffStat: Sendable, Equatable {
    public var files: Int
    public var additions: Int
    public var deletions: Int

    public init(files: Int, additions: Int, deletions: Int) {
        self.files = files
        self.additions = additions
        self.deletions = deletions
    }

    public init(_ files: [FileDiff]) {
        self.init(files: files.count, additions: files.reduce(0) { $0 + $1.additions }, deletions: files.reduce(0) { $0 + $1.deletions })
    }
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

    /// What follows the header's ranges: a space and the function context, or nothing.
    var section: Substring {
        guard header.hasPrefix("@@"), let close = header.dropFirst(2).range(of: "@@") else { return "" }
        return header[close.upperBound...]
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

/// Splits files into those to review and those hidden by default: a vendored dependency tree
/// under the repository's root `vendor/` (and, if asked, documentation as Linguist names it),
/// lockfiles, code whose first lines Linguist takes for generated, and whatever the repository's
/// `.gitattributes` marks generated or vendored. An attribute set to false keeps a path that
/// would otherwise be hidden.
public struct PathFilter: Sendable {
    public var hidesDocumentation: Bool

    public static let `default` = PathFilter()

    /// Lockfiles, which Linguist hides as generated by inspecting their content.
    public static let lockfiles: Set<String> = ["go.sum", "package-lock.json", "yarn.lock", "pnpm-lock.yaml"]

    public init(hidesDocumentation: Bool = false) {
        self.hidesDocumentation = hidesDocumentation
    }

    /// Whether `path` is hidden, given its attributes and, if read, its first lines as
    /// `linesNeeded(toDecide:attributes:)` asks for them. Without them, its content counts for nothing.
    public func excludes(_ path: String, attributes: LinguistAttributes = LinguistAttributes(), head: String? = nil) -> Bool {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if attributes.generated ?? (Self.lockfiles.contains(name) || head.map { GeneratedCode.isGenerated(path: path, head: $0) } ?? false) { return true }
        // Linguist's vendor list is for language statistics and names common source directories,
        // so only a root `vendor/`, the dependency tree Go commits, is taken as vendored.
        if attributes.vendored ?? path.hasPrefix("vendor/") { return true }
        return hidesDocumentation && (attributes.documentation ?? Linguist.documentation.matches(path))
    }

    /// How many of its first lines must be read to decide whether `path` is hidden, or nil when
    /// its name and attributes decide it already, so most files are never read.
    public func linesNeeded(toDecide path: String, attributes: LinguistAttributes = LinguistAttributes()) -> Int? {
        guard attributes.generated == nil, !excludes(path, attributes: attributes) else { return nil }
        return GeneratedCode.linesNeeded(forPath: path)
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

/// A path's `linguist-generated`, `linguist-vendored` and `linguist-documentation` attributes
/// from `.gitattributes`: nil where unspecified, so Linguist's own rules apply.
public struct LinguistAttributes: Sendable, Equatable {
    public var generated: Bool?
    public var vendored: Bool?
    public var documentation: Bool?

    public init(generated: Bool? = nil, vendored: Bool? = nil, documentation: Bool? = nil) {
        self.generated = generated
        self.vendored = vendored
        self.documentation = documentation
    }
}
