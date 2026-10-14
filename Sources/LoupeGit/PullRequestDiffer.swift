import Foundation

/// Produces a PR's diff from a local checkout, in two steps so progress can be shown between
/// them: `fetch` brings the PR's commits in, `diff` compares them with where the PR branched off.
/// Vendored, lockfile and `linguist-generated` paths are left out of the diff and listed instead.
public struct PullRequestDiffer: Sendable {
    /// How long a fetch may take, which is network-bound and can be slow on a big repo.
    public var fetchTimeout: Duration
    /// How long each local git command may take.
    public var localTimeout: Duration

    public init(fetchTimeout: Duration = .seconds(120), localTimeout: Duration = .seconds(60)) {
        self.fetchTimeout = fetchTimeout
        self.localTimeout = localTimeout
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
        let text = try await git(["diff", "--no-color", "--no-ext-diff", "-M"] + range + ["--", "."] + Self.hidden.map { ":(exclude,\($0.magic))\($0.path)" }, in: checkout)
        let hidden = try await git(["diff", "--name-only", "-z", "--no-ext-diff", "-M"] + range + ["--"] + Self.hidden.map { ":(\($0.magic))\($0.path)" }, in: checkout)
        return PullRequestDiff(
            headOid: fetched.headOid,
            mergeBase: mergeBase,
            text: text,
            hiddenPaths: hidden.split(separator: "\0").map(String.init)
        )
    }

    /// Paths left out of the diff, as pathspecs: vendored code, Go's lockfile, and whatever the
    /// checkout's `.gitattributes` marks `linguist-generated` (set, or set to `true`).
    private static let hidden: [(magic: String, path: String)] = [
        ("top", "vendor"),
        ("top", "go.sum"),
        ("attr:linguist-generated", ""),
        ("attr:linguist-generated=true", ""),
    ]

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
