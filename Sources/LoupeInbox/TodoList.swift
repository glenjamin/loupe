import Foundation
import LoupeModel

/// The lists as one list of what to do next: PRs awaiting the viewer's review, then their own
/// recent PRs nearest done first, then their own recent PRs that wait on someone else, apart, then
/// their own PRs gone quiet, by how long.
public struct TodoList: Sendable, Equatable {
    /// Waiting on the viewer's review, longest asked first.
    public let review: [TodoItem]
    /// The viewer's own recently active PRs with something for them to do, nearest done first,
    /// then most self-reviewed.
    public let yours: [TodoItem]
    /// The viewer's own recently active PRs waiting on reviewers or checks, most self-reviewed
    /// then most recently updated first.
    public let waiting: [TodoItem]
    /// The viewer's own PRs quiet for over a month but not six: those with something for them to
    /// do nearest done first, then those waiting on others, each most self-reviewed then most
    /// recently updated first.
    public let overAMonth: [TodoItem]
    /// The viewer's own PRs quiet for over six months, ordered as `overAMonth`.
    public let overSixMonths: [TodoItem]

    public var isEmpty: Bool {
        review.isEmpty && yours.isEmpty && waiting.isEmpty && overAMonth.isEmpty && overSixMonths.isEmpty
    }
}

/// One row of the TODO view: a PR, why it's where it is, what else is broken on it, and for the
/// viewer's own stacks, the rest of the stack above it, which the row stands for.
public struct TodoItem: Sendable, Equatable, Identifiable {
    public let pullRequest: PullRequestSummary
    public let reason: TodoReason
    /// On the viewer's own PR, what's broken that the reason doesn't already say. It never moves
    /// the PR, whose place is down to what reviewers make of it.
    public let problems: [TodoProblem]
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
    case approvedChecksFailing
    case approvedConflicts
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
        case .approvedChecksFailing: "Approved · checks failing"
        case .approvedConflicts: "Approved · conflicts"
        case .changesRequested: "Changes requested"
        case .requestReviewers: "Request reviewers"
        case .draft: "Draft"
        case .waitingOnReview: "Waiting on review"
        case .pushedSinceChangesRequested: "Pushed since changes requested"
        }
    }

    /// The viewer's own PR's reason: what's left to do for it, or that it waits on others. It
    /// follows what reviewers make of the PR; conflicts and failing checks only say why an
    /// approved one can't merge yet.
    init(yours pullRequest: PullRequestSummary) {
        let checks = pullRequest.checks
        let pending = checks == .pending || checks == .expected
        let state = pullRequest.mergeStateStatus ?? .unknown
        let problems = TodoProblem.all(of: pullRequest)
        let pushedSinceChangesRequested = pullRequest.changesRequestedCommitOid.map { $0 != pullRequest.headRefOid } ?? false
        if pullRequest.isDraft || state == .draft {
            self = .draft
        } else if pullRequest.reviewDecision == .approved {
            self = if problems.contains(.conflicts) { .approvedConflicts }
            else if problems.contains(.checksFailing) { .approvedChecksFailing }
            else if pending { .approvedChecksRunning }
            else if state == .behind { .approvedBehind }
            else if [.clean, .hasHooks, .unstable].contains(state) { .readyToMerge }
            else if state == .blocked { .approvedBlocked }
            else { .approvedChecking }
        } else if pullRequest.reviewDecision == .changesRequested, !pushedSinceChangesRequested {
            self = .changesRequested
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
        case .approvedChecksFailing, .approvedConflicts: 3
        case .changesRequested: 4
        case .requestReviewers: 5
        case .draft: 6
        case .waitingOnReview, .pushedSinceChangesRequested, .reviewRequested, .reRequested, .updatedSinceReview: nil
        }
    }
}

/// Something broken on one of the viewer's own PRs, theirs to fix whatever reviewers say.
public enum TodoProblem: Sendable, Hashable {
    case conflicts
    case checksFailing

    public var label: String {
        switch self {
        case .conflicts: "Conflicts"
        case .checksFailing: "Checks failing"
        }
    }

    /// What's broken on the PR, leaving out what its reason already says.
    static func all(of pullRequest: PullRequestSummary, besides reason: TodoReason? = nil) -> [TodoProblem] {
        let conflicts = pullRequest.mergeable == .conflicting || pullRequest.mergeStateStatus == .dirty
        let failing = pullRequest.checks == .failure || pullRequest.checks == .error
        var problems: [TodoProblem] = []
        if conflicts, reason != .approvedConflicts { problems.append(.conflicts) }
        if failing, reason != .approvedChecksFailing { problems.append(.checksFailing) }
        return problems
    }
}

extension PullRequestListModel {
    /// The lists as the TODO view shows them. Review holds what's listed in To review awaiting
    /// the viewer, or updated since their review, oldest request first by when they were first
    /// asked, so a PR asked again is nearer done than a new one; stale requests stay out as in
    /// the lists, as do PRs the viewer approved that only wait to be merged. The viewer's own
    /// open PRs active within `staleAge` go in Yours by how near done they are, the most
    /// self-reviewed then most recently updated first within each step, or in Waiting when only
    /// others can move them on; quieter ones go in a section by how long they've been quiet,
    /// Yours' order then Waiting's. A stack of their PRs is one row, for its lowest listed PR,
    /// ranked and placed by that PR. While searching, only what matches is placed, a stack's
    /// matches grouped among themselves, so a match above one that doesn't is its own row.
    public func todo() -> TodoList {
        // A search lists stale requests too, which stay out of Review.
        let review = pullRequests(in: .toReview).filter { !isStale($0, in: .toReview) }.compactMap { pullRequest -> TodoItem? in
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
            return TodoItem(pullRequest: pullRequest, reason: reason, problems: [], list: .toReview, parent: stacks.parent(of: pullRequest), stacked: [])
        }
        .sorted { Self.firstAsked($0.pullRequest) < Self.firstAsked($1.pullRequest) }

        var mine: [TodoItem] = []
        for listed in listing(in: .mine) {
            if listed.depth > 0, let bottom = mine.popLast() {
                mine.append(TodoItem(pullRequest: bottom.pullRequest, reason: bottom.reason, problems: bottom.problems, list: .mine, parent: bottom.parent, stacked: bottom.stacked + [listed]))
            } else {
                let reason = TodoReason(yours: listed.pullRequest)
                let problems = TodoProblem.all(of: listed.pullRequest, besides: reason)
                mine.append(TodoItem(pullRequest: listed.pullRequest, reason: reason, problems: problems, list: .mine, parent: listed.parent, stacked: []))
            }
        }
        let quiet = Dictionary(grouping: mine) { item in
            let interval = now().timeIntervalSince(item.pullRequest.updatedAt)
            return interval > Self.longQuietAge ? QuietFor.overSixMonths : interval > Self.staleAge ? .overAMonth : .recently
        }
        let recent = quiet[.recently, default: []]
        return TodoList(
            review: review,
            yours: nearestDoneFirst(recent.filter { $0.reason.tier != nil }),
            waiting: nearestDoneFirst(recent.filter { $0.reason.tier == nil }),
            overAMonth: nearestDoneFirst(quiet[.overAMonth, default: []]),
            overSixMonths: nearestDoneFirst(quiet[.overSixMonths, default: []])
        )
    }

    /// Nearest done first, then those that wait on others; within each, the most self-reviewed
    /// first, as a self-review readies a PR for others, then the most recently updated.
    private func nearestDoneFirst(_ items: [TodoItem]) -> [TodoItem] {
        let selfReviewed = Dictionary(uniqueKeysWithValues: items.map { ($0.id, selfReview(of: $0.pullRequest)?.fraction ?? 0) })
        return items.sorted { a, b in
            let (tierA, tierB) = (a.reason.tier ?? Int.max, b.reason.tier ?? Int.max)
            guard tierA == tierB else { return tierA < tierB }
            let (reviewedA, reviewedB) = (selfReviewed[a.id, default: 0], selfReviewed[b.id, default: 0])
            return reviewedA == reviewedB ? a.pullRequest.updatedAt > b.pullRequest.updatedAt : reviewedA > reviewedB
        }
    }

    /// When the viewer was first asked to review the PR, as far as known.
    private static func firstAsked(_ pullRequest: PullRequestSummary) -> Date {
        pullRequest.firstReviewRequestedAt ?? pullRequest.reviewRequestedAt ?? pullRequest.updatedAt
    }
}

/// How long one of the viewer's own PRs has gone without activity, by TODO mode's sections.
private enum QuietFor {
    case recently
    case overAMonth
    case overSixMonths
}
