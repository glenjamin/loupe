import Foundation
import LoupeCore

/// Produces a PR's diff from a local checkout, in two steps so progress can be shown between
/// them: `fetch` brings the PR's commits in, `diff` compares them with where the PR branched off.
/// Paths `PathFilter` hides (vendored, lockfiles, generated) are left out of the diff and listed instead.
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

    /// Fetches PR `number`'s head into `refs/loupe/pull/<number>/head`, and makes sure its base is
    /// present: `baseRefOid` when known, fetching `baseRefName` if it's missing.
    public func fetch(number: Int, baseRefName: String, baseRefOid: String?, in checkout: URL) async throws -> FetchedPullRequest {
        let head = "refs/loupe/pull/\(number)/head"
        try await git(["fetch", "--no-tags", "--no-write-fetch-head", "origin", "+refs/pull/\(number)/head:\(head)"], in: checkout, timeout: fetchTimeout)
        let headOid = try await git(["rev-parse", "--verify", "\(head)^{commit}"], in: checkout).trimmingCharacters(in: .whitespacesAndNewlines)

        // Without a known oid, the remote-tracking branch the fetch updates stands in.
        let base = baseRefOid ?? "refs/remotes/origin/\(baseRefName)"
        if await !Git.succeeds(["cat-file", "-e", "\(base)^{commit}"], in: checkout) {
            try await git(["fetch", "--no-tags", "--no-write-fetch-head", "origin", baseRefName], in: checkout, timeout: fetchTimeout)
        }
        return FetchedPullRequest(number: number, headOid: headOid, base: base)
    }

    /// The fetched PR's changes since it branched off its base.
    public func diff(_ fetched: FetchedPullRequest, in checkout: URL) async throws -> PullRequestDiff {
        let mergeBase = try await git(["merge-base", fetched.base, fetched.headOid], in: checkout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let range = [mergeBase, fetched.headOid]
        let changed = try await git(["diff", "--name-only", "-z", "--no-ext-diff", "-M"] + range, in: checkout)
            .split(separator: "\0").map(String.init)
        let attributes = try await linguistAttributes(of: changed, in: checkout)
        let hidden = changed.filter { filter.excludes($0, attributes: attributes[$0] ?? LinguistAttributes()) }
        let excludes = coveringPaths(hiding: hidden, keeping: changed).map { ":(exclude,top,literal)\($0)" }
        let text = try await git(["diff", "--no-color", "--no-ext-diff", "-M"] + range + ["--", "."] + excludes, in: checkout)
        return PullRequestDiff(headOid: fetched.headOid, mergeBase: mergeBase, text: text, hiddenPaths: hidden)
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

    @discardableResult
    private func git(_ arguments: [String], in checkout: URL, timeout: Duration? = nil) async throws -> String {
        try await Git.run(arguments, in: checkout, timeout: timeout ?? localTimeout)
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
    /// `git diff` output, without the hidden paths.
    public let text: String
    /// Changed paths left out of `text`.
    public let hiddenPaths: [String]
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
