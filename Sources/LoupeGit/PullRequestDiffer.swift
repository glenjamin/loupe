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
    /// Where the trees and blobs Loupe merges are written, an object directory of its own shared
    /// by every checkout, as checkouts are only fetched into.
    public var replayedObjects: URL

    public init(fetchTimeout: Duration = .seconds(120), localTimeout: Duration = .seconds(60), filter: PathFilter = .default, replayedObjects: URL = Self.defaultReplayedObjects) {
        self.fetchTimeout = fetchTimeout
        self.localTimeout = localTimeout
        self.filter = filter
        self.replayedObjects = replayedObjects
    }

    /// `~/Library/Caches/Loupe/replayed-objects`: made again whenever it's needed, so the system
    /// may clear it.
    public static var defaultReplayedObjects: URL {
        URL.cachesDirectory.appending(components: "Loupe", "replayed-objects", directoryHint: .isDirectory)
    }

    /// Fetches PR `number` of `repository` (`owner/name`) into `refs/loupe/pull/<number>/head`,
    /// and makes sure its base is present: `baseRefOid` when known, fetching `baseRefName` if it's
    /// missing. Both come from the checkout's remote for that repo, or `origin` if none matches.
    public func fetch(number: Int, of repository: String, baseRefName: String, baseRefOid: String?, in checkout: URL) async throws -> FetchedPullRequest {
        let remote = await Git.remotes(of: checkout).matching(repository)?.name ?? "origin"
        let head = "refs/loupe/pull/\(number)/head"
        try await fetch([remote, "+refs/pull/\(number)/head:\(head)"], in: checkout)
        let headOid = try await git(["rev-parse", "--verify", "\(head)^{commit}"], in: checkout).trimmingCharacters(in: .whitespacesAndNewlines)

        // Without a known oid, the remote-tracking branch the fetch updates stands in.
        let base = baseRefOid ?? "refs/remotes/\(remote)/\(baseRefName)"
        if await !Git.succeeds(["cat-file", "-e", "\(base)^{commit}"], in: checkout) {
            try await fetch([remote, baseRefName], in: checkout)
        }
        return FetchedPullRequest(number: number, headOid: headOid, base: base)
    }

    /// The fetched PR's changes since it branched off its base, and its commits.
    public func diff(_ fetched: FetchedPullRequest, in checkout: URL) async throws -> PullRequestDiff {
        let mergeBase = try await git(["merge-base", fetched.base, fetched.headOid], in: checkout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let commits = try await commits(from: mergeBase, to: fetched.headOid, in: checkout)
        let changes = try await diff(DiffRange(base: mergeBase, head: fetched.headOid), in: checkout)
        return PullRequestDiff(headOid: fetched.headOid, base: fetched.base, mergeBase: mergeBase, commits: commits, text: changes.text, hidden: changes.hidden)
    }

    /// Whether `oid`, an earlier head of PR `repository`, is still in the history of `head`, so
    /// the changes since it are `oid..head`, or the PR was rebased since. Either commit the
    /// checkout lacks is fetched by oid from the repo's remote, with no ref made for it.
    public func ancestry(of oid: String, toHead head: String, of repository: String, in checkout: URL) async throws -> Ancestry {
        var missing: [String] = []
        for commit in [oid, head] where await !Git.succeeds(["cat-file", "-e", "\(commit)^{commit}"], in: checkout) {
            missing.append(commit)
        }
        if !missing.isEmpty {
            let remote = await Git.remotes(of: checkout).matching(repository)?.name ?? "origin"
            try await fetch([remote] + missing, in: checkout)
        }
        do {
            try await git(["merge-base", "--is-ancestor", oid, head], in: checkout)
            return .ancestor
        } catch let error as GitError where error.status == 1 {
            return .rebased
        }
    }

    /// The PR's changes as they were at `oldHead`, replayed onto where `head` branched off
    /// `base`, so diffing the replay to `head` shows only what the author changed since, and
    /// nothing `base` gained meanwhile. A file whose old changes don't apply cleanly there takes
    /// its version at `oldHead` instead, so it shows its whole change since, base's included.
    /// The replay is made with `git merge-tree`, its objects written to `replayedObjects`.
    public func replay(_ oldHead: String, onto head: String, base: String, in checkout: URL) async throws -> Replay {
        async let oldMergeBase = git(["merge-base", base, oldHead], in: checkout)
        async let newMergeBase = git(["merge-base", base, head], in: checkout)
        async let headTree = git(["rev-parse", "--verify", "\(head)^{tree}"], in: checkout)
        let writing = try await writingOwnObjects(in: checkout)
        let merged = try await mergeTree(["--merge-base=\(try await oldMergeBase.trimmed)", try await newMergeBase.trimmed, oldHead], in: checkout, environment: writing)
        let unseparated = merged.conflicted
        let replayed = unseparated.isEmpty ? merged.tree : try await taking(unseparated, from: oldHead, into: merged.tree, in: checkout, environment: writing)
        return Replay(tree: replayed, head: head, unseparated: unseparated, isUnchanged: replayed == (try await headTree.trimmed))
    }

    /// The paths that conflict when `head`, of PR `number`, is merged into branch `baseRefName`
    /// as the remote has it now, as merging the PR on GitHub would find them, in git's order;
    /// none when it merges cleanly. The branch's tip is fetched into
    /// `refs/loupe/pull/<number>/base` because GitHub judges conflicts against it, while the
    /// PR's `baseRefOid` stays where the base was when the head was last pushed. Worked out with
    /// `git merge-tree`, which leaves the checkout's branches, index and working tree alone, its
    /// objects written to `replayedObjects`.
    public func conflicts(mergingHead head: String, of number: Int, of repository: String, into baseRefName: String, in checkout: URL) async throws -> [String] {
        let remote = await Git.remotes(of: checkout).matching(repository)?.name ?? "origin"
        let base = "refs/loupe/pull/\(number)/base"
        try await fetch([remote, "+refs/heads/\(baseRefName):\(base)"], in: checkout)
        return try await mergeTree([base, head], in: checkout, environment: writingOwnObjects(in: checkout)).conflicted
    }

    /// The changes between two commits: the diff of the paths to review, and the hidden paths
    /// listed but not diffed, as a vendored tree can be enormous. `ignoringWhitespace` diffs
    /// as github.com's "Hide whitespace" does, leaving out files only whitespace changed in;
    /// the hidden paths are the same either way, but their counts leave whitespace out too.
    public func diff(_ range: DiffRange, ignoringWhitespace: Bool = false, in checkout: URL) async throws -> RangeDiff {
        let changed = try await changedFiles(in: range, checkout: checkout)
        let hiding = try await hiddenPaths(changedIn: [range: changed.map(\.path)], checkout: checkout)[range] ?? []
        var hidden = changed.filter { hiding.contains($0.path) }
        let covering = coveringPaths(hiding: hidden.map(\.path), keeping: changed.map(\.path))
        let excludes = covering.map { ":(exclude,top,literal)\($0)" }
        async let text = git(["diff", "--no-color", "--no-ext-diff", "-M"] + Self.whitespace(ignoringWhitespace) + [range.base, range.head, "--", "."] + excludes, in: checkout)
        let counts = try await lineCounts(in: range, under: covering + hidden.compactMap(\.renamedFrom), ignoringWhitespace: ignoringWhitespace, checkout: checkout)
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
    /// `ignoringWhitespace` leaves changes to whitespace uncounted, but still counts the files
    /// only whitespace changed in, as the diff still lists them.
    public func stats(of ranges: [DiffRange], ignoringWhitespace: Bool = false, in checkout: URL) async throws -> [DiffRange: DiffStat] {
        let counts = try await withThrowingTaskGroup(of: (DiffRange, [String: LineCount]).self) { group in
            var counts: [DiffRange: [String: LineCount]] = [:]
            var pending = ranges[...]
            func startNext() {
                guard let range = pending.popFirst() else { return }
                group.addTask {
                    guard ignoringWhitespace else { return (range, try await lineCounts(in: range, checkout: checkout)) }
                    async let ignoring = lineCounts(in: range, ignoringWhitespace: true, checkout: checkout)
                    let changed = try await lineCounts(in: range, checkout: checkout)
                    let counted = try await ignoring
                    return (range, changed.mapValues { _ in LineCount(additions: 0, deletions: 0, isBinary: false) }.merging(counted) { $1 })
                }
            }
            for _ in 0..<Self.concurrentRuns { startNext() }
            while let (range, count) = try await group.next() {
                counts[range] = count
                startNext()
            }
            return counts
        }
        let hidden = try await hiddenPaths(changedIn: counts.mapValues { Array($0.keys) }, checkout: checkout)
        return counts.reduce(into: [:]) { stats, entry in
            let hiding = hidden[entry.key] ?? []
            let reviewed = entry.value.filter { !hiding.contains($0.key) }.values
            stats[entry.key] = DiffStat(files: reviewed.count, additions: reviewed.reduce(0) { $0 + $1.additions }, deletions: reviewed.reduce(0) { $0 + $1.deletions })
        }
    }

    /// One file's diff over `range`, such as a hidden file's once it's asked for. A rename's
    /// old path is included so git still sees the rename.
    public func diff(of file: ChangedFile, in range: DiffRange, ignoringWhitespace: Bool = false, checkout: URL) async throws -> String {
        let paths = [file.renamedFrom, file.path].compactMap { $0 }.map { ":(top,literal)\($0)" }
        return try await git(["diff", "--no-color", "--no-ext-diff", "-M"] + Self.whitespace(ignoringWhitespace) + [range.base, range.head, "--"] + paths, in: checkout)
    }

    /// `-w`, as github.com's "Hide whitespace" (`?w=1`) ignores all of it, indentation and
    /// spaces between words alike.
    private static func whitespace(_ ignoring: Bool) -> [String] {
        ignoring ? ["--ignore-all-space"] : []
    }

    /// The file at `path`, from the repo's root, as it is in commit `oid`.
    public func contents(of path: String, at oid: String, in checkout: URL) async throws -> String {
        try await git(["show", "--no-textconv", "\(oid):\(path)"], in: checkout)
    }

    /// The bytes of the file at `path` in commit `oid`, or only its size when that's over `limit`,
    /// so a huge file is never read into memory.
    public func blob(of path: String, at oid: String, in checkout: URL, limit: Int) async throws -> Blob {
        let object = "\(oid):\(path)"
        let bytes = Int(try await git(["cat-file", "-s", object], in: checkout).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if bytes > limit { return .tooLarge(bytes: bytes) }
        return .contents(try await Git.data(["cat-file", "blob", object], in: checkout, environment: readingReplays, timeout: localTimeout))
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
    private func lineCounts(in range: DiffRange, under paths: [String], ignoringWhitespace: Bool, checkout: URL) async throws -> [String: LineCount] {
        guard !paths.isEmpty else { return [:] }
        return try await lineCounts(in: range, ignoringWhitespace: ignoringWhitespace, checkout: checkout, pathspecs: paths.map { ":(top,literal)\($0)" })
    }

    /// Lines added and deleted in each path changed in `range`, or only under `pathspecs`.
    /// Ignoring whitespace, git leaves out the paths only whitespace changed in.
    private func lineCounts(in range: DiffRange, ignoringWhitespace: Bool = false, checkout: URL, pathspecs: [String] = []) async throws -> [String: LineCount] {
        let fields = try await git(["diff", "--numstat", "-z", "--no-ext-diff", "-M"] + Self.whitespace(ignoringWhitespace) + [range.base, range.head, "--"] + pathspecs, in: checkout)
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

    /// Which of the paths changed in each range `filter` hides: by path and attributes, and for a
    /// path only its content can decide, by its first lines. Those are read from git as the range
    /// leaves the file, or for a deleted one as it was before, all in one run however many ranges.
    private func hiddenPaths(changedIn changes: [DiffRange: [String]], checkout: URL) async throws -> [DiffRange: Set<String>] {
        let attributes = try await linguistAttributes(of: changes, in: checkout)
        var hidden: [DiffRange: Set<String>] = [:]
        var undecided: [(range: DiffRange, path: String, lines: Int, attributes: LinguistAttributes)] = []
        for (range, paths) in changes {
            for path in paths {
                let given = attributes[range.head]?[path] ?? LinguistAttributes()
                if filter.excludes(path, attributes: given) {
                    hidden[range, default: []].insert(path)
                } else if let lines = filter.linesNeeded(toDecide: path, attributes: given) {
                    undecided.append((range, path, lines, given))
                }
            }
        }
        guard !undecided.isEmpty else { return hidden }
        var heads = try await Git.firstLines(of: undecided.map { ("\($0.range.head):\($0.path)", $0.lines) }, in: checkout, environment: readingReplays, timeout: localTimeout)
        // Missing at the range's head means deleted in it.
        let deleted = heads.indices.filter { heads[$0] == nil }
        if !deleted.isEmpty {
            let before = try await Git.firstLines(of: deleted.map { ("\(undecided[$0].range.base):\(undecided[$0].path)", undecided[$0].lines) }, in: checkout, environment: readingReplays, timeout: localTimeout)
            for (index, head) in zip(deleted, before) { heads[index] = head }
        }
        for (file, head) in zip(undecided, heads) where filter.excludes(file.path, attributes: file.attributes, head: head) {
            hidden[file.range, default: []].insert(file.path)
        }
        return hidden
    }

    /// The `linguist-*` attributes each range's head gives its paths, by head oid. They're read
    /// from that commit's `.gitattributes` files, as GitHub reads them, since the checkout's
    /// working tree can be on any branch. A path deleted at the head takes the head's too.
    private func linguistAttributes(of changes: [DiffRange: [String]], in checkout: URL) async throws -> [String: [String: LinguistAttributes]] {
        var pathsByHead: [String: Set<String>] = [:]
        for (range, paths) in changes where !paths.isEmpty {
            pathsByHead[range.head, default: []].formUnion(paths)
        }
        guard !pathsByHead.isEmpty else { return [:] }
        let files = try await attributeFiles(at: pathsByHead, in: checkout)
        return try await withThrowingTaskGroup(of: (String, [String: LinguistAttributes]).self) { group in
            var attributes: [String: [String: LinguistAttributes]] = [:]
            var pending = pathsByHead[...]
            func startNext() {
                guard let (head, paths) = pending.popFirst() else { return }
                group.addTask { (head, try await linguistAttributes(of: paths.sorted(), given: files[head] ?? [], in: checkout)) }
            }
            for _ in 0..<Self.concurrentRuns { startNext() }
            while let (head, given) = try await group.next() {
                attributes[head] = given
                startNext()
            }
            return attributes
        }
    }

    /// The `.gitattributes` files at each head that could apply to its paths, those in the
    /// paths' directories and above, all found by one `git cat-file --batch-check`.
    private func attributeFiles(at pathsByHead: [String: Set<String>], in checkout: URL) async throws -> [String: [AttributeFile]] {
        var candidates: [(head: String, path: String)] = []
        for (head, paths) in pathsByHead {
            var directories: Set<Substring> = [""]
            for path in paths {
                var directory = path[...]
                while let slash = directory.lastIndex(of: "/") {
                    directory = directory[..<slash]
                    guard directories.insert(directory).inserted else { break }
                }
            }
            for directory in directories {
                let file = directory.isEmpty ? ".gitattributes" : "\(directory)/.gitattributes"
                // Batch input is one name per line.
                if !file.contains("\n") { candidates.append((head, file)) }
            }
        }
        let input = Data(candidates.map { "\($0.head):\($0.path)\n" }.joined().utf8)
        let output = try await git(["cat-file", "--batch-check=%(objecttype) %(objectname)"], in: checkout, input: input)
        var files: [String: [AttributeFile]] = [:]
        for (candidate, line) in zip(candidates, output.split(separator: "\n", omittingEmptySubsequences: false)) {
            let fields = line.split(separator: " ")
            guard fields.count == 2, fields[0] == "blob" else { continue }
            files[candidate.head, default: []].append(AttributeFile(path: candidate.path, oid: String(fields[1])))
        }
        return files
    }

    /// The `linguist-*` attributes `files` give each path. git before 2.40 can't read attributes
    /// from a commit, so they're put in an index of their own, outside the checkout, for
    /// `check-attr --cached` to read in place of the working tree's.
    private func linguistAttributes(of paths: [String], given files: [AttributeFile], in checkout: URL) async throws -> [String: LinguistAttributes] {
        guard !paths.isEmpty else { return [:] }
        let index = FileManager.default.temporaryDirectory.appending(path: "loupe-attributes-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let environment = ["GIT_INDEX_FILE": index.path(percentEncoded: false)]
        if !files.isEmpty {
            let entries = Data(files.map { "100644 blob \($0.oid)\t\($0.path)\0" }.joined().utf8)
            _ = try await Git.run(["-c", "core.splitIndex=false", "update-index", "-z", "--index-info"], in: checkout, input: entries, environment: environment, timeout: localTimeout)
        }
        let input = Data(paths.map { $0 + "\0" }.joined().utf8)
        let output = try await Git.run(["check-attr", "--cached", "-z", "--stdin", "linguist-generated", "linguist-vendored", "linguist-documentation"], in: checkout, input: input, environment: environment, timeout: localTimeout)
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

    /// `tree` with each of `paths` as `commit` has it, or without it where `commit` has none,
    /// written as a tree of its own through an index outside the checkout.
    private func taking(_ paths: [String], from commit: String, into tree: String, in checkout: URL, environment: [String: String]) async throws -> String {
        let index = FileManager.default.temporaryDirectory.appending(path: "loupe-replay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        var environment = environment
        environment["GIT_INDEX_FILE"] = index.path(percentEncoded: false)
        func run(_ arguments: [String], input: Data? = nil, literally: Bool = false) async throws -> String {
            try await Git.run(["-c", "core.splitIndex=false"] + arguments, in: checkout, input: input, environment: literally ? environment.merging(["GIT_LITERAL_PATHSPECS": "1"]) { $1 } : environment, timeout: localTimeout)
        }
        _ = try await run(["read-tree", tree])
        // `<mode> <type> <oid>TAB<path>`, which `--index-info` takes as it is.
        let listing = try await run(["ls-tree", "-r", "-z", "--full-tree", commit, "--"] + paths, literally: true)
        var entries: [String: Substring] = [:]
        for entry in listing.split(separator: "\0") {
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            entries[String(entry[entry.index(after: tab)...])] = entry
        }
        let removal = "0 \(String(repeating: "0", count: tree.count))\t"
        let input = Data(paths.map { (entries[$0].map(String.init) ?? removal + $0) + "\0" }.joined().utf8)
        _ = try await run(["update-index", "-z", "--index-info"], input: input)
        return try await run(["write-tree"]).trimmed
    }

    /// `git merge-tree` of `revisions`: the merged tree, and the paths it couldn't merge.
    private func mergeTree(_ revisions: [String], in checkout: URL, environment: [String: String]) async throws -> (tree: String, conflicted: [String]) {
        let merged = try await Git.run(
            ["merge-tree", "--write-tree", "-z", "--name-only", "--no-messages"] + revisions,
            in: checkout, environment: environment, timeout: localTimeout, succeedingOn: [0, 1]
        )
        // `<tree>NUL`, then for conflicts each conflicted path NUL and an empty field.
        var fields = merged.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        let tree = fields.removeFirst()
        var listed: Set<String> = []
        return (tree, fields.prefix { !$0.isEmpty }.filter { listed.insert($0).inserted })
    }

    /// Has git write objects to Loupe's object directory, reading the checkout's through it.
    private func writingOwnObjects(in checkout: URL) async throws -> [String: String] {
        let ownObjects = try await git(["rev-parse", "--path-format=absolute", "--git-path", "objects"], in: checkout)
        try FileManager.default.createDirectory(at: replayedObjects, withIntermediateDirectories: true)
        return [
            "GIT_OBJECT_DIRECTORY": replayedObjects.path(percentEncoded: false),
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": ownObjects.trimmed,
        ]
    }

    /// Lets a local git run read the objects replays have written, as diffing a replay needs.
    private var readingReplays: [String: String] {
        let path = replayedObjects.path(percentEncoded: false)
        return FileManager.default.fileExists(atPath: path) ? ["GIT_ALTERNATE_OBJECT_DIRECTORIES": path] : [:]
    }

    /// Runs a local git command, which can read replays' objects.
    @discardableResult
    private func git(_ arguments: [String], in checkout: URL, input: Data? = nil) async throws -> String {
        try await Git.run(arguments, in: checkout, input: input, environment: readingReplays, timeout: localTimeout)
    }

    /// Fetches into the checkout. Replays' objects are kept out of its sight, or it could take
    /// one for its own and not fetch it, leaving the checkout without it.
    private func fetch(_ arguments: [String], in checkout: URL) async throws {
        _ = try await Git.run(["fetch", "--no-tags", "--no-write-fetch-head"] + arguments, in: checkout, timeout: fetchTimeout)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// A file's bytes as one commit has them, or its size when it's too big to read.
public enum Blob: Sendable, Equatable {
    case contents(Data)
    case tooLarge(bytes: Int)
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
    /// The base commit's oid, or the remote-tracking ref standing in for it.
    public let base: String
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

/// How an earlier head of a PR stands to its head now.
public enum Ancestry: Sendable, Equatable {
    /// In the head's history: the PR has only gained commits since.
    case ancestor
    /// Not in it: the PR was rebased or force-pushed since.
    case rebased
}

/// An earlier head's changes replayed onto where a later head branched off its base.
public struct Replay: Sendable, Hashable {
    /// The replayed tree, in Loupe's object directory or, if nothing needed making, the checkout.
    public let tree: String
    public let head: String
    /// The paths whose old changes didn't apply cleanly, which the tree has as the earlier
    /// head had them.
    public let unseparated: [String]
    /// Whether the replay is the head's own tree: the head was only rebased since.
    public let isUnchanged: Bool

    /// What the author changed between the two heads.
    public var range: DiffRange { DiffRange(base: tree, head: head) }
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

/// A `.gitattributes` file in some commit, by its path from the repo's root.
private struct AttributeFile: Sendable {
    let path: String
    let oid: String
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
