import Foundation
import LoupeCore

/// Produces a PR's diff from a local checkout, in two steps so progress can be shown between
/// them: `fetch` brings the PR's commits in, `diff` compares them with where the PR branched off.
/// Paths `PathFilter` hides (vendored, lockfiles, generated) are left out of the diff and listed
/// instead, each diffable on its own when asked for.
public struct PullRequestDiffer: Sendable {
    /// How long a fetch may take, which is network-bound and can be slow on a big repo.
    public var fetchTimeout: Duration
    /// How long each local git command may take.
    public var localTimeout: Duration

    public var filter: PathFilter

    public init(fetchTimeout: Duration = .seconds(120), localTimeout: Duration = .seconds(60), filter: PathFilter = .default) {
        self.fetchTimeout = fetchTimeout
        self.localTimeout = localTimeout
        self.filter = filter
    }

    /// Fetches PR `number` of `repository` (`owner/name`) into `refs/loupe/pull/<number>/head`,
    /// and makes sure its base is present: `baseRefOid` when known, fetching `baseRefName` if it's
    /// missing. Both come from the checkout's remote for that repo, or `origin` if none matches.
    public func fetch(number: Int, of repository: String, baseRefName: String, baseRefOid: String?, in checkout: URL) async throws -> FetchedPullRequest {
        let remote = await Git.remotes(of: checkout).matching(repository)?.name ?? "origin"
        let head = "refs/loupe/pull/\(number)/head"
        try await git(["fetch", "--no-tags", "--no-write-fetch-head", remote, "+refs/pull/\(number)/head:\(head)"], in: checkout, timeout: fetchTimeout)
        let headOid = try await git(["rev-parse", "--verify", "\(head)^{commit}"], in: checkout).trimmingCharacters(in: .whitespacesAndNewlines)

        // Without a known oid, the remote-tracking branch the fetch updates stands in.
        let base = baseRefOid ?? "refs/remotes/\(remote)/\(baseRefName)"
        if await !Git.succeeds(["cat-file", "-e", "\(base)^{commit}"], in: checkout) {
            try await git(["fetch", "--no-tags", "--no-write-fetch-head", remote, baseRefName], in: checkout, timeout: fetchTimeout)
        }
        return FetchedPullRequest(number: number, headOid: headOid, base: base)
    }

    /// The fetched PR's changes since it branched off its base, and its commits.
    public func diff(_ fetched: FetchedPullRequest, in checkout: URL) async throws -> PullRequestDiff {
        let mergeBase = try await git(["merge-base", fetched.base, fetched.headOid], in: checkout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commits = try await commits(from: mergeBase, to: fetched.headOid, in: checkout)
        let changes = try await diff(DiffRange(base: mergeBase, head: fetched.headOid), in: checkout)
        return PullRequestDiff(headOid: fetched.headOid, mergeBase: mergeBase, commits: commits, text: changes.text, hidden: changes.hidden)
    }

    /// The changes between two commits: the diff of the paths to review, and the hidden paths
    /// listed but not diffed, as a vendored tree can be enormous.
    public func diff(_ range: DiffRange, in checkout: URL) async throws -> RangeDiff {
        let changed = try await changedFiles(in: range, checkout: checkout)
        let attributes = try await linguistAttributes(of: changed.map(\.path), in: checkout)
        var hidden = changed.filter { filter.excludes($0.path, attributes: attributes[$0.path] ?? LinguistAttributes()) }
        let covering = coveringPaths(hiding: hidden.map(\.path), keeping: changed.map(\.path))
        let excludes = covering.map { ":(exclude,top,literal)\($0)" }
        async let text = git(["diff", "--no-color", "--no-ext-diff", "-M", range.base, range.head, "--", "."] + excludes, in: checkout)
        let counts = try await lineCounts(in: range, under: covering + hidden.compactMap(\.renamedFrom), checkout: checkout)
        for index in hidden.indices {
            guard let count = counts[hidden[index].path] else { continue }
            hidden[index].additions = count.additions
            hidden[index].deletions = count.deletions
            hidden[index].isBinary = count.isBinary
        }
        return RangeDiff(text: try await text, hidden: hidden)
    }

    /// How much each range changes the files to review, leaving out those `PathFilter` hides as
    /// the diff does. Each range is counted by a git run of its own, a few at a time.
    public func stats(of ranges: [DiffRange], in checkout: URL) async throws -> [DiffRange: DiffStat] {
        let counts = try await withThrowingTaskGroup(of: (DiffRange, [String: LineCount]).self) { group in
            var counts: [DiffRange: [String: LineCount]] = [:]
            var pending = ranges[...]
            func startNext() {
                guard let range = pending.popFirst() else { return }
                group.addTask { (range, try await lineCounts(in: range, checkout: checkout)) }
            }
            for _ in 0..<Self.concurrentRuns { startNext() }
            while let (range, count) = try await group.next() {
                counts[range] = count
                startNext()
            }
            return counts
        }
        let attributes = try await linguistAttributes(of: Set(counts.values.flatMap(\.keys)).sorted(), in: checkout)
        return counts.mapValues { counts in
            let reviewed = counts.filter { !filter.excludes($0.key, attributes: attributes[$0.key] ?? LinguistAttributes()) }.values
            return DiffStat(files: reviewed.count, additions: reviewed.reduce(0) { $0 + $1.additions }, deletions: reviewed.reduce(0) { $0 + $1.deletions })
        }
    }

    /// One file's diff over `range`, such as a hidden file's once it's asked for. A rename's
    /// old path is included so git still sees the rename.
    public func diff(of file: ChangedFile, in range: DiffRange, checkout: URL) async throws -> String {
        let paths = [file.renamedFrom, file.path].compactMap { $0 }.map { ":(top,literal)\($0)" }
        return try await git(["diff", "--no-color", "--no-ext-diff", "-M", range.base, range.head, "--"] + paths, in: checkout)
    }

    /// The file at `path`, from the repo's root, as it is in commit `oid`.
    public func contents(of path: String, at oid: String, in checkout: URL) async throws -> String {
        try await git(["show", "--no-textconv", "\(oid):\(path)"], in: checkout)
    }

    /// The commits after `base` up to `head`, oldest first.
    private func commits(from base: String, to head: String, in checkout: URL) async throws -> [PullRequestCommit] {
        let log = try await git(["log", "--reverse", "-z", "--format=%H%x1f%P%x1f%s", "\(base)..\(head)"], in: checkout)
        var emptyTree: String?
        var commits: [PullRequestCommit] = []
        for record in log.split(separator: "\0") {
            let fields = record.trimmingCharacters(in: .newlines).split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            // A root commit's changes are taken from the empty tree.
            let parent: String
            if let first = fields[1].split(separator: " ").first {
                parent = String(first)
            } else if let emptyTree {
                parent = emptyTree
            } else {
                parent = try await git(["hash-object", "-t", "tree", "--stdin"], in: checkout, input: Data()).trimmingCharacters(in: .whitespacesAndNewlines)
                emptyTree = parent
            }
            commits.append(PullRequestCommit(oid: fields[0], headline: fields[2], range: DiffRange(base: parent, head: fields[0])))
        }
        return commits
    }

    /// Every path changed in `range`, with what happened to it.
    private func changedFiles(in range: DiffRange, checkout: URL) async throws -> [ChangedFile] {
        let fields = try await git(["diff", "--name-status", "-z", "--no-ext-diff", "-M", range.base, range.head], in: checkout)
            .split(separator: "\0").map(String.init)
        var files: [ChangedFile] = []
        var index = 0
        while index + 1 < fields.count {
            let status = fields[index]
            let similarity = Int(status.dropFirst()) ?? 0
            switch status.first {
            case "R", "C":
                guard index + 2 < fields.count else { return files }
                let from = fields[index + 1]
                let change: FileDiff.Change = status.first == "R" ? .renamed(from: from, similarity: similarity) : .copied(from: from, similarity: similarity)
                files.append(ChangedFile(path: fields[index + 2], change: change))
                index += 3
            default:
                let change: FileDiff.Change = switch status.first {
                case "A": .added
                case "D": .deleted
                default: .modified
                }
                files.append(ChangedFile(path: fields[index + 1], change: change))
                index += 2
            }
        }
        return files
    }

    /// Lines added and deleted in each path changed under `paths`, by its new path, without
    /// producing the diff itself. A rename's old path belongs among `paths` so git still sees
    /// the rename.
    private func lineCounts(in range: DiffRange, under paths: [String], checkout: URL) async throws -> [String: LineCount] {
        guard !paths.isEmpty else { return [:] }
        return try await lineCounts(in: range, checkout: checkout, pathspecs: paths.map { ":(top,literal)\($0)" })
    }

    /// Lines added and deleted in each path changed in `range`, or only under `pathspecs`.
    private func lineCounts(in range: DiffRange, checkout: URL, pathspecs: [String] = []) async throws -> [String: LineCount] {
        let fields = try await git(["diff", "--numstat", "-z", "--no-ext-diff", "-M", range.base, range.head, "--"] + pathspecs, in: checkout)
            .split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var counts: [String: LineCount] = [:]
        var index = 0
        while index < fields.count {
            // `added<TAB>deleted<TAB>path`, or with no path for a rename or copy, whose old and
            // new paths follow as fields of their own. A binary file counts `-` for both.
            let columns = fields[index].split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else {
                index += 1
                continue
            }
            let path: String
            if columns[2].isEmpty {
                guard index + 2 < fields.count else { break }
                path = fields[index + 2]
                index += 3
            } else {
                path = String(columns[2])
                index += 1
            }
            let additions = Int(columns[0])
            let deletions = Int(columns[1])
            counts[path] = LineCount(additions: additions ?? 0, deletions: deletions ?? 0, isBinary: additions == nil && deletions == nil)
        }
        return counts
    }

    /// The `linguist-*` attributes the checkout's `.gitattributes` gives each path.
    private func linguistAttributes(of paths: [String], in checkout: URL) async throws -> [String: LinguistAttributes] {
        guard !paths.isEmpty else { return [:] }
        let input = Data(paths.map { $0 + "\0" }.joined().utf8)
        let output = try await Git.run(["check-attr", "-z", "--stdin", "linguist-generated", "linguist-vendored", "linguist-documentation"], in: checkout, input: input, timeout: localTimeout)
        let fields = output.split(separator: "\0", omittingEmptySubsequences: false)
        var attributes: [String: LinguistAttributes] = [:]
        for start in stride(from: 0, to: fields.count - 2, by: 3) {
            let path = String(fields[start])
            let value: Bool? = switch fields[start + 2] {
            case "set", "true": true
            case "unset", "false": false
            default: nil
            }
            switch fields[start + 1] {
            case "linguist-generated": attributes[path, default: LinguistAttributes()].generated = value
            case "linguist-vendored": attributes[path, default: LinguistAttributes()].vendored = value
            default: attributes[path, default: LinguistAttributes()].documentation = value
            }
        }
        return attributes
    }

    /// How many ranges `stats` counts at once: enough to use the cores, without a git process
    /// for every commit of a long PR at the same time.
    private static let concurrentRuns = 8

    @discardableResult
    private func git(_ arguments: [String], in checkout: URL, input: Data? = nil, timeout: Duration? = nil) async throws -> String {
        try await Git.run(arguments, in: checkout, input: input, timeout: timeout ?? localTimeout)
    }
}

/// A PR whose head and base commits are present in the checkout.
public struct FetchedPullRequest: Sendable, Equatable {
    public let number: Int
    public let headOid: String
    /// The base commit's oid, or the remote-tracking ref standing in for it.
    public let base: String
}

public struct PullRequestDiff: Sendable, Equatable {
    public let headOid: String
    /// Where the PR branched off its base, which the diff is taken from.
    public let mergeBase: String
    /// The PR's commits, oldest first.
    public let commits: [PullRequestCommit]
    /// `git diff` output, without the hidden paths.
    public let text: String
    /// Changed paths left out of `text`.
    public let hidden: [ChangedFile]

    public var range: DiffRange { DiffRange(base: mergeBase, head: headOid) }
}

/// The changes between two commits, as `PullRequestDiffer` makes them.
public struct RangeDiff: Sendable, Equatable {
    /// `git diff` output, without the hidden paths.
    public let text: String
    /// Changed paths left out of `text`.
    public let hidden: [ChangedFile]
}

/// What `git diff <base> <head>` compares.
public struct DiffRange: Sendable, Hashable {
    public let base: String
    public let head: String

    public init(base: String, head: String) {
        self.base = base
        self.head = head
    }
}

public struct PullRequestCommit: Sendable, Equatable, Identifiable {
    public let oid: String
    /// The first line of its message.
    public let headline: String
    /// Its own changes: from its first parent, or from nothing for a root commit.
    public let range: DiffRange

    public var id: String { oid }
}

private struct LineCount: Sendable {
    let additions: Int
    let deletions: Int
    let isBinary: Bool
}

/// The fewest paths that cover every hidden path and no kept one: each hidden path's highest
/// directory holding no kept path, so a vendored tree is excluded as one pathspec.
private func coveringPaths(hiding hidden: [String], keeping changed: [String]) -> [String] {
    let hiddenSet = Set(hidden)
    var keptDirectories: Set<Substring> = []
    for path in changed where !hiddenSet.contains(path) {
        var directory = path[...]
        while let slash = directory.lastIndex(of: "/") {
            directory = directory[..<slash]
            keptDirectories.insert(directory)
        }
    }
    var covering: Set<String> = []
    for path in hidden {
        var cover = path[...]
        var search = path.startIndex
        while let slash = path[search...].firstIndex(of: "/") {
            let directory = path[..<slash]
            if !keptDirectories.contains(directory) {
                cover = directory
                break
            }
            search = path.index(after: slash)
        }
        covering.insert(String(cover))
    }
    return covering.sorted()
}
