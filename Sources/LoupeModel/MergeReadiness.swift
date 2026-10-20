/// Whether an open PR can be merged from Loupe now, and if not, the first reason why, in the
/// order a reader would fix them.
public enum MergeReadiness: Sendable, Equatable {
    /// GitHub would merge it (`CLEAN`, `HAS_HOOKS` or `UNSTABLE`) and it's approved.
    case ready
    /// A draft, whatever its reviews, conflicts or checks: its next step is leaving draft.
    case draft
    case blocked(MergeBlocker)
    /// GitHub hasn't worked out whether it can merge yet, or hasn't been asked.
    case checking

    /// Nil once the PR is merged or closed, as there's nothing left to merge.
    public init?(_ pullRequest: PullRequestSummary) {
        guard pullRequest.state == .open else { return nil }
        let state = pullRequest.mergeStateStatus ?? .unknown
        let base = pullRequest.baseRefName
        if pullRequest.isDraft || state == .draft {
            self = .draft
        } else if state == .dirty || pullRequest.mergeable == .conflicting {
            self = .blocked(.conflicts(base: base))
        } else if pullRequest.reviewDecision == .changesRequested {
            self = .blocked(.changesRequested)
        } else if pullRequest.reviewDecision != .approved {
            // No decision at all, from a base that doesn't require reviews, counts as not
            // approved too: only approved PRs are merged from here.
            self = .blocked(.notApproved)
        } else if state == .blocked {
            let failing = pullRequest.checks == .failure || pullRequest.checks == .error
            self = .blocked(failing ? .checksFailing : .branchProtection)
        } else if state == .behind {
            self = .blocked(.behind(base: base))
        } else if [.clean, .hasHooks, .unstable].contains(state) {
            self = .ready
        } else {
            self = .checking
        }
    }
}

/// Why a PR that isn't a draft can't be merged.
public enum MergeBlocker: Sendable, Equatable {
    case conflicts(base: String)
    case changesRequested
    case notApproved
    case checksFailing
    /// Blocked by the base branch's rules for some other reason, such as checks still running.
    case branchProtection
    case behind(base: String)
    /// Stacked on open PR `number`, the bottom of its stack, which merges first. `cascades` when
    /// GitHub's own stack links them, as merging there would merge every PR below it too.
    case stacked(on: Int, cascades: Bool)

    /// A few words to show beside the merge button.
    public var description: String {
        switch self {
        case let .stacked(number, _): "Merge #\(number) first"
        case let .conflicts(base): "Conflicts with \(base)"
        case .changesRequested: "Changes requested"
        case .notApproved: "Not approved"
        case .checksFailing: "Checks failing"
        case .branchProtection: "Blocked by branch protection"
        case let .behind(base): "Behind \(base)"
        }
    }
}
