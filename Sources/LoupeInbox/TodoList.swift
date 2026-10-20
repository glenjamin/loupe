import Foundation
import LoupeModel

/// The lists as one list of what to do next: PRs awaiting the viewer's review, then their own
/// PRs nearest done first, then their own PRs that wait on someone else, apart.
public struct TodoList: Sendable, Equatable {
    /// Waiting on the viewer's review, longest asked first.
    public let review: [TodoItem]
    /// The viewer's own PRs with something for them to do, nearest done first.
    public let yours: [TodoItem]
    /// The viewer's own PRs waiting on reviewers or checks, most recently updated first.
    public let waiting: [TodoItem]

    public var isEmpty: Bool {
        review.isEmpty && yours.isEmpty && waiting.isEmpty
    }
}

/// One row of the TODO view: a PR, why it's where it is, and for the viewer's own stacks, the
/// rest of the stack above it, which the row stands for.
public struct TodoItem: Sendable, Equatable, Identifiable {
    public let pullRequest: PullRequestSummary
    public let reason: TodoReason
    /// The list the PR comes from, which says how its row is drawn.
    public let list: PullRequestList
    /// The open PR it's stacked on, listed or not.
    public let parent: PullRequestSummary?
    /// The viewer's PRs stacked above it, bottom first, each with how many of those below it
    /// in the stack are listed, this one included.
    public let stacked: [StackedPullRequest]

    public var id: String { pullRequest.id }
}

/// Why a PR is where it is in the TODO view.
public enum TodoReason: Sendable, Equatable {
    /// Awaiting the viewer's first look.
    case reviewRequested
    /// Asked of the viewer again since their review.
    case reRequested
    /// Pushed to since the viewer's review, which was of this kind.
    case updatedSinceReview(ViewerReviewMark.Kind)
    case readyToMerge
    case approvedChecksRunning
    case approvedBehind
    /// Approved, but GitHub hasn't yet said whether it can merge.
    case approvedChecking
    /// Approved with its checks passing, but held by the base branch's other rules.
    case approvedBlocked
    case checksFailing
    case conflicts
    /// Changes requested, with nothing pushed since.
    case changesRequested
    case requestReviewers
    case draft
    case waitingOnReview
    case pushedSinceChangesRequested

    /// A few words for the row.
    public var label: String {
        switch self {
        case .reviewRequested: "Review requested"
        case .reRequested: "Re-requested"
        case .updatedSinceReview(.approved): "Updated since you approved"
        case .updatedSinceReview(.changesRequested): "Updated since you requested changes"
        case .updatedSinceReview: "Updated since your review"
        case .readyToMerge: "Ready to merge"
        case .approvedChecksRunning: "Approved · checks running"
        case .approvedBehind: "Approved · behind"
        case .approvedChecking: "Approved · checking"
        case .approvedBlocked: "Approved · blocked"
        case .checksFailing: "Checks failing"
        case .conflicts: "Conflicts"
        case .changesRequested: "Changes requested"
        case .requestReviewers: "Request reviewers"
        case .draft: "Draft"
        case .waitingOnReview: "Waiting on review"
        case .pushedSinceChangesRequested: "Pushed since changes requested"
        }
    }

    /// The viewer's own PR's reason: what's left to do for it, or that it waits on others.
    init(yours pullRequest: PullRequestSummary) {
        let checks = pullRequest.checks
        let failing = checks == .failure || checks == .error
        let pending = checks == .pending || checks == .expected
        let state = pullRequest.mergeStateStatus ?? .unknown
        let conflicts = pullRequest.mergeable == .conflicting || state == .dirty
        let pushedSinceChangesRequested = pullRequest.changesRequestedCommitOid.map { $0 != pullRequest.headRefOid } ?? false
        if pullRequest.isDraft || state == .draft {
            self = .draft
        } else if pullRequest.reviewDecision == .approved {
            self = if conflicts { .conflicts }
            else if failing { .checksFailing }
            else if pending { .approvedChecksRunning }
            else if state == .behind { .approvedBehind }
            else if [.clean, .hasHooks, .unstable].contains(state) { .readyToMerge }
            else if state == .blocked { .approvedBlocked }
            else { .approvedChecking }
        } else if pullRequest.reviewDecision == .changesRequested, !pushedSinceChangesRequested {
            self = .changesRequested
        } else if conflicts {
            self = .conflicts
        } else if failing {
            self = .checksFailing
        } else if pullRequest.reviewDecision == .changesRequested {
            self = .pushedSinceChangesRequested
        } else if pullRequest.requestedReviewers?.isEmpty == true {
            self = .requestReviewers
        } else {
            self = .waitingOnReview
        }
    }

    /// Nearest done first, nil for a PR that waits on others.
    var tier: Int? {
        switch self {
        case .readyToMerge: 1
        case .approvedChecksRunning, .approvedBehind, .approvedChecking, .approvedBlocked: 2
        case .checksFailing, .conflicts: 3
        case .changesRequested: 4
        case .requestReviewers: 5
        case .draft: 6
        case .waitingOnReview, .pushedSinceChangesRequested, .reviewRequested, .reRequested, .updatedSinceReview: nil
        }
    }
}

extension PullRequestListModel {
    /// The lists as the TODO view shows them. Review holds what's listed in To review awaiting
    /// the viewer, or updated since their review, oldest request first by when they were first
    /// asked, so a PR asked again is nearer done than a new one; stale requests stay out as in
    /// the lists, as do PRs the viewer approved that only wait to be merged. The viewer's own
    /// open PRs go in Yours by how near done they are, most recently updated first within each
    /// step, or in Waiting when only others can move them on. A stack of their PRs is one row,
    /// for its lowest listed PR, ranked by that PR.
    public func todo() -> TodoList {
        let review = pullRequests(in: .toReview).compactMap { pullRequest -> TodoItem? in
            let mark = reviewMark(on: pullRequest, in: .toReview)
            let reason: TodoReason
            if verdict(on: pullRequest, in: .toReview) == nil {
                let reRequested = mark?.updates.contains { if case .reRequested = $0 { true } else { false } } ?? false
                reason = reRequested ? .reRequested : .reviewRequested
            } else if let mark, mark.isUpdated {
                reason = .updatedSinceReview(mark.kind)
            } else {
                return nil
            }
            return TodoItem(pullRequest: pullRequest, reason: reason, list: .toReview, parent: stacks.parent(of: pullRequest), stacked: [])
        }
        .sorted { Self.firstAsked($0.pullRequest) < Self.firstAsked($1.pullRequest) }

        var mine: [TodoItem] = []
        for listed in listing(in: .mine) {
            if listed.depth > 0, let bottom = mine.popLast() {
                mine.append(TodoItem(pullRequest: bottom.pullRequest, reason: bottom.reason, list: .mine, parent: bottom.parent, stacked: bottom.stacked + [listed]))
            } else {
                mine.append(TodoItem(pullRequest: listed.pullRequest, reason: TodoReason(yours: listed.pullRequest), list: .mine, parent: listed.parent, stacked: []))
            }
        }
        let newestFirst = { (a: TodoItem, b: TodoItem) in a.pullRequest.updatedAt > b.pullRequest.updatedAt }
        let yours = mine.filter { $0.reason.tier != nil }.sorted { a, b in
            let (tierA, tierB) = (a.reason.tier ?? 0, b.reason.tier ?? 0)
            return tierA == tierB ? newestFirst(a, b) : tierA < tierB
        }
        return TodoList(review: review, yours: yours, waiting: mine.filter { $0.reason.tier == nil }.sorted(by: newestFirst))
    }

    /// When the viewer was first asked to review the PR, as far as known.
    private static func firstAsked(_ pullRequest: PullRequestSummary) -> Date {
        pullRequest.firstReviewRequestedAt ?? pullRequest.reviewRequestedAt ?? pullRequest.updatedAt
    }
}
