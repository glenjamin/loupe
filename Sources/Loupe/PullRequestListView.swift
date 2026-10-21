import AppKit
import LoupeInbox
import LoupeModel
import SwiftUI

/// The start screen: the user's own open PRs beside the ones waiting on their review, or the
/// two as one list of what to do next.
struct PullRequestListView: View {
    let model: PullRequestListModel
    let showsClosed: Bool
    var mode: ListMode = .lists

    var body: some View {
        Group {
            if model.hasStoredLists {
                Group {
                    switch mode {
                    case .lists where model.isSearching && PullRequestList.allCases.allSatisfy({ model.pullRequests(in: $0, includingClosed: showsClosed).isEmpty }):
                        NoSearchMatches(text: model.searchText)
                    case .lists:
                        HStack(spacing: 0) {
                            PullRequestColumn(title: "Mine", list: .mine, showsAuthor: false, showsClosed: showsClosed, model: model)
                            Divider()
                            PullRequestColumn(title: "To review", list: .toReview, showsAuthor: true, showsClosed: showsClosed, model: model)
                        }
                    case .todo:
                        TodoListView(model: model)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    if let error = model.error {
                        RefreshErrorBanner(error: error, lastRefreshed: model.lastRefreshed, isLoading: model.isLoading) {
                            Task { await model.refresh() }
                        }
                    }
                }
            } else if let error = model.error {
                ContentUnavailableView {
                    Label("Couldn't load pull requests", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { Task { await model.refresh() } }
                        .disabled(model.isLoading)
                }
            } else {
                ProgressView("Loading pull requests…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// In place of the lists when nothing in them matches the search.
struct NoSearchMatches: View {
    let text: String

    var body: some View {
        ContentUnavailableView {
            Label("No pull requests match “\(text.trimmingCharacters(in: .whitespaces))”", systemImage: "magnifyingglass")
        } description: {
            Text("Search matches titles, repos, numbers, authors, branches and requested reviewers. Press Esc to clear it.")
        }
    }
}

/// Shown above lists that couldn't be refreshed, so it's clear how old they are.
struct RefreshErrorBanner: View {
    let error: String
    let lastRefreshed: Date?
    let isLoading: Bool
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                // Each "N ago" label ticks itself, as a tick further up leaves unchanged views be.
                EveryMinute { now in
                    Text(headline(now: now)).font(.callout.weight(.semibold))
                }
                Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button("Retry", action: retry).disabled(isLoading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func headline(now: Date) -> String {
        guard let lastRefreshed else { return "Couldn't refresh pull requests" }
        return "Couldn't refresh. Showing pull requests from \(lastRefreshed.ago(now: now))."
    }
}

struct PullRequestColumn: View {
    let title: String
    let list: PullRequestList
    let showsAuthor: Bool
    let showsClosed: Bool
    let model: PullRequestListModel
    /// Moved with the arrow keys; Return opens it.
    @State private var selection: PullRequestSummary.ID?
    /// Lists the PRs held back as stale, for this session only.
    @State private var showsStale = false

    var body: some View {
        let listing = model.listing(in: list, includingClosed: showsClosed, includingStale: showsStale)
        let pullRequests = listing.map(\.pullRequest)
        VStack(alignment: .leading, spacing: 0) {
            Text("\(title) (\(pullRequests.count))")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if pullRequests.isEmpty {
                Text(model.isSearching ? "No matches" : "Nothing here")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(listing, selection: $selection) { listed in
                    let pullRequest = listed.pullRequest
                    Button { model.open(pullRequest) } label: {
                        PullRequestRow(pullRequest: pullRequest, showsAuthor: showsAuthor, showsReviewRequired: list != .toReview, selfReview: model.selfReview(of: pullRequest), staleRequestedAt: staleRequestedAt(of: pullRequest), verdict: model.verdict(on: pullRequest, in: list), stackedOn: listed.parent, reviewMark: model.reviewMark(on: pullRequest, in: list))
                            .padding(.leading, CGFloat(listed.depth) * Self.stackIndent)
                    }
                    .buttonStyle(.plain)
                    .contextMenu { CheckoutMenu(repository: pullRequest.repository, model: model) }
                }
                .onKeyPress(.return) {
                    guard let pullRequest = pullRequests.first(where: { $0.id == selection }) else { return .ignored }
                    model.open(pullRequest)
                    return .handled
                }
            }
            let stale = model.staleCount(in: list, includingClosed: showsClosed)
            if stale > 0 {
                Button(showsStale ? "Hide \(stale) older than a month" : "\(stale) older than a month hidden") {
                    showsStale.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .background(StaleToggleMarker())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// How far each PR in a stack is stepped in from the one below it.
    private static let stackIndent: CGFloat = 16

    /// When the viewer was asked to review a PR listed only because the hidden ones are shown,
    /// so its row can say how long it has waited. A verdict's row, or one in Mine, has its own
    /// time instead.
    private func staleRequestedAt(of pullRequest: PullRequestSummary) -> Date? {
        guard list == .toReview, model.isStale(pullRequest, in: list), model.verdict(on: pullRequest, in: list) == nil else { return nil }
        return pullRequest.reviewRequestedAt ?? pullRequest.updatedAt
    }
}

/// A row's context menu: its repo's checkout revealed in Finder, or located if not found.
struct CheckoutMenu: View {
    let repository: String
    let model: PullRequestListModel

    var body: some View {
        switch model.checkout(for: repository) {
        case let .found(directory):
            Button("Reveal Checkout in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([directory])
            }
        case .notFound:
            Button("Locate Checkout…") {
                locateCheckout(of: repository, startingAt: model.checkoutSearchRoots.first) { directory in
                    try await model.locateCheckout(for: repository, at: directory)
                }
            }
        case nil:
            EmptyView()
        }
    }
}

struct PullRequestRow: View {
    let pullRequest: PullRequestSummary
    let showsAuthor: Bool
    /// Off where every PR is awaiting the viewer's review, so saying a review is required or
    /// asked for would say nothing.
    let showsReviewRequired: Bool
    /// Set on the viewer's own PR whose current head has been diffed here.
    let selfReview: SelfReview?
    /// Set on a PR whose request for review is old enough to be hidden by default.
    var staleRequestedAt: Date? = nil
    /// The viewer's approval or request for changes, set where that's why the PR is listed.
    var verdict: ReviewState? = nil
    /// The open PR it's stacked on, if any.
    var stackedOn: PullRequestSummary? = nil
    /// Set in To review where the viewer has reviewed the PR.
    var reviewMark: ViewerReviewMark? = nil
    /// Set in the TODO view, saying why the PR is where it is.
    var reason: TodoReason? = nil
    /// Set in the TODO view on the viewer's own PR, saying what's broken besides the reason.
    var problems: [TodoProblem] = []
    /// Set in the TODO view on a stack's row, to show or hide the PRs stacked on it.
    var stack: StackDisclosure? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The repo and number lead, as that's how PRs get talked about; the owner is
            // secondary and is the first thing to truncate in a narrow column.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(repositoryName(pullRequest)) #\(pullRequest.number)")
                    .font(.headline.monospacedDigit())
                    .layoutPriority(1)
                if let reason {
                    TodoReasonBadge(reason: reason)
                }
                ForEach(problems, id: \.self) { problem in
                    Badge(text: problem.label, tint: .diffDanger)
                }
                // The reason or problems may already say it.
                if reason != .draft {
                    StateBadge(pullRequest: pullRequest, showsOpen: false)
                }
                if reason != .approvedConflicts, !problems.contains(.conflicts) {
                    ConflictsBadge(pullRequest: pullRequest)
                }
                SelfReviewBadge(selfReview: selfReview)
                if let stackedOn {
                    StackedOnLabel(parent: stackedOn)
                }
                stack
                Text(owner)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            Text(pullRequest.title).lineLimit(2)
            HStack(spacing: 8) {
                if showsAuthor, let author = pullRequest.author {
                    Text(author)
                }
                if let reviewMark {
                    EveryMinute { now in
                        ViewerReviewBadge(mark: reviewMark, now: now)
                    }
                }
                // GitHub's verdict repeats the viewer's when they're the same.
                if showsReviewRequired || ([.approved, .changesRequested].contains(pullRequest.reviewDecision) && pullRequest.reviewDecision?.rawValue != verdict?.rawValue) {
                    ReviewDecisionLabel(decision: pullRequest.reviewDecision, requestedReviewers: pullRequest.requestedReviewers)
                }
                if let checks = pullRequest.checks {
                    ChecksIcon(state: checks, contexts: pullRequest.checkContexts)
                }
                Spacer(minLength: 0)
                // Each "N ago" label ticks itself, as a tick further up leaves unchanged views be.
                if let staleRequestedAt {
                    EveryMinute { now in
                        Text("requested \(staleRequestedAt.ago(now: now))")
                            .foregroundStyle(.tertiary)
                    }
                }
                EveryMinute { now in
                    Text(pullRequest.updatedAt.ago(now: now))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
        .opacity(pullRequest.state == .open ? 1 : 0.55)
        .contentShape(Rectangle())
    }

    private var owner: String {
        pullRequest.repository.split(separator: "/").first.map(String.init) ?? ""
    }
}

struct Badge: View {
    let text: String
    let tint: Color
    /// Said after the text, in the attention colour, for what's changed about it.
    var aside: String? = nil

    var body: some View {
        label
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
    }

    private var label: Text {
        guard let aside else { return Text(text) }
        return Text(text) + Text(verbatim: " · \(aside)").foregroundStyle(.diffAttention)
    }
}

/// Merged, closed or draft; open only where asked, as lists mostly hold open PRs.
struct StateBadge: View {
    let pullRequest: PullRequestSummary
    let showsOpen: Bool

    var body: some View {
        switch pullRequest.state {
        case .merged: Badge(text: "Merged", tint: .purple)
        case .closed: Badge(text: "Closed", tint: .diffDanger)
        case .open, .unknown:
            if pullRequest.isDraft {
                Badge(text: "Draft", tint: .primary)
            } else if showsOpen {
                Badge(text: "Open", tint: .diffSuccess)
            }
        }
    }
}

/// Shown only when GitHub says the PR conflicts with its base; nothing while it's still working
/// that out.
struct ConflictsBadge: View {
    let pullRequest: PullRequestSummary

    var body: some View {
        if pullRequest.mergeable == .conflicting {
            Badge(text: "Conflicts", tint: .diffDanger)
                .help("This branch has conflicts that must be resolved before it can be merged")
        }
    }
}

/// Shown on the viewer's own PR once they've marked every file to review viewed, so it's ready
/// for others to review. Known only to Loupe; nothing changes on GitHub.
struct SelfReviewedBadge: View {
    let isSelfReviewed: Bool
    /// Set on a PR whose request for review is old enough to be hidden by default.
    var staleRequestedAt: Date? = nil

    var body: some View {
        if isSelfReviewed {
            Badge(text: "Self-reviewed", tint: .diffSuccess)
                .help("You've marked every file to review as viewed, so it's ready for others to review")
        }
    }
}

/// How far the viewer has reviewed their own PR: "Self-reviewed" once done, and quietly how many
/// files are viewed while part way, so a PR nearly ready for others shows it. Nothing before the
/// first file is viewed.
struct SelfReviewBadge: View {
    let selfReview: SelfReview?

    var body: some View {
        if let selfReview, selfReview.isComplete {
            SelfReviewedBadge(isSelfReviewed: true)
        } else if let selfReview, selfReview.viewed > 0 {
            Badge(text: "Self-reviewed \(selfReview.viewed) of \(selfReview.total)", tint: .secondary)
                .help(Text(verbatim: "You've marked \(selfReview.viewed) of the \(selfReview.total) files to review as viewed"))
        }
    }
}

/// What the viewer's reviews of a PR in To review come to: "You approved", "You requested
/// changes" or "You commented", with "· updated" once there's been a push or a request to look
/// again since their latest review, so what needs another look stands out while the verdict
/// stays readable. Its tooltip says when, and what's changed.
struct ViewerReviewBadge: View {
    let mark: ViewerReviewMark
    /// What the tooltip's "N ago" is from.
    var now: Date = .now

    var body: some View {
        Badge(text: title, tint: tint, aside: mark.isUpdated ? "updated" : nil)
            .help(tooltip)
    }

    private var title: String {
        switch mark.kind {
        case .approved: "You approved"
        case .changesRequested: "You requested changes"
        case .commented: "You commented"
        case .dismissed: "You reviewed"
        }
    }

    private var tint: Color {
        switch mark.kind {
        case .approved: .diffSuccess
        case .changesRequested: .diffDanger
        case .commented, .dismissed: .secondary
        }
    }

    /// e.g. "You approved this 2 days ago. Since then: 2 commits pushed, the newest committed
    /// 3 hours ago; you were asked to review it again 1 hour ago."
    private var tooltip: String {
        var said = switch mark.kind {
        case .approved: "You approved this"
        case .changesRequested: "You requested changes"
        case .commented: "You commented on this"
        case .dismissed: "You reviewed this"
        }
        said += when(mark.givenAt)
        if let reviewedAt = mark.reviewedAt, reviewedAt != mark.givenAt {
            said += ", and last reviewed it\(when(reviewedAt))"
        }
        if mark.kind == .dismissed {
            said += ", but your review was dismissed"
        }
        guard mark.isUpdated else {
            return switch mark.kind {
            case .approved: "\(said), with no changes since; it's waiting to be merged"
            case .changesRequested: "\(said), with no changes since; it's waiting on its author"
            case .commented, .dismissed: "\(said), with no changes since"
            }
        }
        return "\(said). Since then: \(mark.updates.map(describe).joined(separator: "; "))."
    }

    private func describe(_ update: ViewerReviewMark.Update) -> String {
        switch update {
        case let .commits(count, lastCommittedAt):
            guard count > 1 else { return "a commit pushed" + (lastCommittedAt.map { ", committed\(when($0))" } ?? "") }
            return "\(count) commits pushed" + (lastCommittedAt.map { ", the newest committed\(when($0))" } ?? "")
        case let .forcePushed(at): return "force-pushed\(when(at))"
        case .changed: return "new commits pushed"
        case let .reRequested(at): return "you were asked to review it again\(when(at))"
        }
    }

    private func when(_ date: Date?) -> String {
        date.map { " \($0.recentOrDated(now: now))" } ?? ""
    }
}

/// Where the PR's review stands: GitHub's verdict once reviewed, otherwise who's been asked,
/// or that a review is required when no one has been.
struct ReviewDecisionLabel: View {
    /// Nil when the base branch doesn't require reviews.
    let decision: ReviewDecision?
    /// Nil until fetched.
    let requestedReviewers: [RequestedReviewer]?

    var body: some View {
        switch decision {
        case .approved: Text("Approved").foregroundStyle(.diffSuccess)
        case .changesRequested: Text("Changes requested").foregroundStyle(.diffDanger)
        case .reviewRequired, .unknown, nil:
            let names = (requestedReviewers ?? []).compactMap(\.name)
            if !names.isEmpty {
                Badge(text: "Review requested: \(names.joined(separator: ", "))", tint: .diffAttention)
                    .help(decision == .reviewRequired ? "Waiting on a review from those asked; one is required before this can be merged" : "Waiting on a review from those asked")
            } else if decision == .reviewRequired {
                Badge(text: "Review required", tint: .diffAttention)
                    .help("A review is required before this can be merged")
            }
        }
    }
}

/// The head commit's overall check state as a bare glyph; resting the pointer on it opens a
/// popover listing each check, as github.com's does.
struct ChecksIcon: View {
    let state: CheckState
    /// Empty until looked up, when the popover only names the overall state.
    let contexts: [CheckContext]

    var body: some View {
        glyph
            .fontWeight(.semibold)
            .background(HoverPopoverAnchor(content:ChecksPopoverContent(state: state, contexts: contexts)))
    }

    @ViewBuilder private var glyph: some View {
        switch state {
        case .success: Image(systemName: "checkmark").foregroundStyle(.diffSuccess)
        case .failure, .error: Image(systemName: "xmark").foregroundStyle(.diffDanger)
        case .pending, .expected: Image(systemName: "clock").foregroundStyle(.orange)
        case .unknown: Image(systemName: "questionmark").foregroundStyle(.secondary)
        }
    }
}

/// Which PR a stacked one sits on, beside GitHub's stack icon.
struct StackedOnLabel: View {
    let parent: PullRequestSummary

    var body: some View {
        Label {
            Text(verbatim: "on #\(parent.number)")
        } icon: {
            Image(systemName: "square.stack.3d.up")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .help("Stacked on \(repositoryName(parent)) #\(parent.number), \(parent.title)")
    }
}

/// Lets the snapshot run find the To review column's caption to click.
struct StaleToggleMarker: NSViewRepresentable {
    final class Marker: NSView {}

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}
