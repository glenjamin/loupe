import Foundation

/// Checks a PR's branch out in the user's checkout, to work on it in an editor. Unlike
/// everything else in Loupe this changes the checkout's branch and working tree, so it runs only
/// when asked, refuses a checkout with uncommitted changes or a merge or rebase under way, and
/// never stashes, resets or discards anything. Loupe's own `refs/loupe/` refs are left alone.
public struct CheckoutSwitcher: Sendable {
    /// How long a fetch may take, which is network-bound.
    public var fetchTimeout: Duration
    /// How long each local git command may take.
    public var localTimeout: Duration

    public init(fetchTimeout: Duration = .seconds(120), localTimeout: Duration = .seconds(60)) {
        self.fetchTimeout = fetchTimeout
        self.localTimeout = localTimeout
    }

    /// Switches `checkout` to PR `number` of `repository` (`owner/name`). A PR whose branch is on
    /// the checkout's remote for the repo gets a local branch of the same name tracking it; one
    /// from a fork, or whose branch has gone, gets a local `pr-<number>` at its head. An existing
    /// local branch is fast-forwarded to the PR's head when it can be, and otherwise left as it is.
    public func switchTo(pullRequest number: Int, of repository: String, headRefName: String, in checkout: URL) async throws -> SwitchedBranch {
        try await ensureClean(checkout)
        let remote = await Git.remotes(of: checkout).matching(repository)?.name ?? "origin"
        let pullRef = "refs/pull/\(number)/head"
        let branchRef = "refs/heads/\(headRefName)"
        let advertised = try await git(["ls-remote", remote, pullRef, branchRef], in: checkout, timeout: fetchTimeout)
            .split(separator: "\n")
            .reduce(into: [String: String]()) { refs, line in
                let fields = line.split(separator: "\t", maxSplits: 1)
                if fields.count == 2 { refs[String(fields[1])] = String(fields[0]) }
            }
        guard let head = advertised[pullRef] else {
            throw CheckoutSwitchError.notOnRemote(pullRef, remote: remote)
        }

        if advertised[branchRef] == head {
            let tracking = "refs/remotes/\(remote)/\(headRefName)"
            try await git(["fetch", "--no-tags", "--no-write-fetch-head", remote, "+\(branchRef):\(tracking)"], in: checkout, timeout: fetchTimeout)
            let target = try await switchBranch(headRefName, to: tracking, creating: ["--track", "\(remote)/\(headRefName)"], in: checkout)
            return SwitchedBranch(name: headRefName, isFork: false, remote: remote, isAtPullRequestHead: target == head)
        }
        try await git(["fetch", "--no-tags", "--no-write-fetch-head", remote, pullRef], in: checkout, timeout: fetchTimeout)
        let name = "pr-\(number)"
        let target = try await switchBranch(name, to: head, creating: [head], in: checkout)
        return SwitchedBranch(name: name, isFork: true, remote: remote, isAtPullRequestHead: target == head)
    }

    /// Throws if the checkout has uncommitted changes, untracked files included, or a merge,
    /// rebase, cherry-pick, revert or bisect under way, any of which a switch could disturb.
    public func ensureClean(_ checkout: URL) async throws {
        let markers = ["rebase-merge", "rebase-apply", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG"]
        let paths = try await git(["rev-parse"] + markers.flatMap { ["--git-path", $0] }, in: checkout)
            .split(separator: "\n").map(String.init)
        for (marker, path) in zip(markers, paths) {
            let url = path.hasPrefix("/") ? URL(filePath: path) : checkout.appending(path: path)
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
                throw CheckoutSwitchError.operationInProgress(operation(marker), checkout: checkout)
            }
        }
        let status = try await git(["status", "--porcelain", "--untracked-files=normal"], in: checkout)
        if !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CheckoutSwitchError.uncommittedChanges(checkout: checkout)
        }
    }

    /// Switches to local branch `name`, creating it from `creating` if it's missing, else
    /// fast-forwarding it to `target` if it's behind. Returns the commit the branch is left at.
    private func switchBranch(_ name: String, to target: String, creating: [String], in checkout: URL) async throws -> String {
        let local = "refs/heads/\(name)"
        if await Git.succeeds(["show-ref", "--verify", "--quiet", local], in: checkout) {
            try await git(["switch", "--quiet", name], in: checkout)
            if await Git.succeeds(["merge-base", "--is-ancestor", local, target], in: checkout) {
                try await git(["merge", "--ff-only", "--quiet", target], in: checkout)
            }
        } else {
            try await git(["switch", "--quiet", "-c", name] + creating, in: checkout)
        }
        return try await git(["rev-parse", "--verify", "HEAD^{commit}"], in: checkout).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    private func git(_ arguments: [String], in checkout: URL, timeout: Duration? = nil) async throws -> String {
        try await Git.run(arguments, in: checkout, timeout: timeout ?? localTimeout)
    }
}

/// The local branch a PR was checked out as.
public struct SwitchedBranch: Sendable, Equatable {
    public let name: String
    /// Whether the PR's branch isn't on the repo's remote, as for a fork's PR, so the local
    /// branch is Loupe's `pr-<N>` and tracks nothing.
    public let isFork: Bool
    /// The checkout's remote for the PR's repo.
    public let remote: String
    /// False when an existing local branch couldn't be fast-forwarded to the PR's head, being
    /// ahead of it or diverged, and was left as it was.
    public let isAtPullRequestHead: Bool
}

public enum CheckoutSwitchError: Error, LocalizedError, Equatable {
    case uncommittedChanges(checkout: URL)
    /// A merge, rebase or the like, by name, is under way.
    case operationInProgress(String, checkout: URL)
    /// The remote doesn't have the PR's ref.
    case notOnRemote(String, remote: String)

    public var errorDescription: String? {
        switch self {
        case let .uncommittedChanges(checkout):
            "\(checkout.path(percentEncoded: false)) has uncommitted changes. Commit or stash them, then try again."
        case let .operationInProgress(operation, checkout):
            "\(checkout.path(percentEncoded: false)) has a \(operation) under way. Finish or abort it, then try again."
        case let .notOnRemote(ref, remote):
            "\(remote) has no \(ref)."
        }
    }
}

/// What a `.git` marker file says is under way.
private func operation(_ marker: String) -> String {
    switch marker {
    case "rebase-merge", "rebase-apply": "rebase"
    case "MERGE_HEAD": "merge"
    case "CHERRY_PICK_HEAD": "cherry-pick"
    case "REVERT_HEAD": "revert"
    default: "bisect"
    }
}
