import AppKit
import LoupeInbox
import LoupeModel
import SwiftUI

/// The start screen: the user's own open PRs beside the ones waiting on their review.
struct PullRequestListView: View {
    let model: PullRequestListModel
    let showsClosed: Bool

    var body: some View {
        Group {
            if model.hasStoredLists {
                HStack(spacing: 0) {
                    PullRequestColumn(title: "Mine", list: .mine, showsAuthor: false, showsClosed: showsClosed, model: model)
                    Divider()
                    PullRequestColumn(title: "To review", list: .toReview, showsAuthor: true, showsClosed: showsClosed, model: model)
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
                TimelineView(.everyMinute) { _ in
                    Text(headline).font(.callout.weight(.semibold))
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

    private var headline: String {
        guard let lastRefreshed else { return "Couldn't refresh pull requests" }
        return "Couldn't refresh. Showing pull requests from \(lastRefreshed.formatted(.relative(presentation: .named)))."
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
    /// Lists the PRs held back for their review request's age, for this session only.
    @State private var showsStaleRequests = false

    var body: some View {
        let pullRequests = model.pullRequests(in: list, includingClosed: showsClosed, includingStaleRequests: showsStaleRequests)
        VStack(alignment: .leading, spacing: 0) {
            Text("\(title) (\(pullRequests.count))")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if pullRequests.isEmpty {
                Text("Nothing here")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(pullRequests, selection: $selection) { pullRequest in
                    let checkout = model.checkout(for: pullRequest.repository)
                    Button { model.open(pullRequest) } label: {
                        PullRequestRow(pullRequest: pullRequest, showsAuthor: showsAuthor, showsReviewRequired: list != .toReview, isSelfReviewed: model.isSelfReviewed(pullRequest), staleRequestedAt: staleRequestedAt(of: pullRequest), verdict: model.verdict(on: pullRequest, in: list))
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        switch checkout {
                        case let .found(directory):
                            Button("Reveal Checkout in Finder") {
                                NSWorkspace.shared.activateFileViewerSelecting([directory])
                            }
                        case .notFound:
                            Button("Locate Checkout…") {
                                locateCheckout(of: pullRequest.repository, startingAt: model.checkoutSearchRoots.first) { directory in
                                    try await model.locateCheckout(for: pullRequest.repository, at: directory)
                                }
                            }
                        case nil:
                            EmptyView()
                        }
                    }
                }
                .onKeyPress(.return) {
                    guard let pullRequest = pullRequests.first(where: { $0.id == selection }) else { return .ignored }
                    model.open(pullRequest)
                    return .handled
                }
            }
            let stale = model.staleRequestCount(in: list, includingClosed: showsClosed)
            if stale > 0 {
                Button(showsStaleRequests ? "Hide \(stale) older than a month" : "\(stale) older than a month hidden") {
                    showsStaleRequests.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .background(StaleRequestsToggleMarker())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// When the viewer was asked to review a PR listed only because the hidden ones are shown,
    /// so its row can say how long it has waited.
    private func staleRequestedAt(of pullRequest: PullRequestSummary) -> Date? {
        guard model.isStaleRequest(pullRequest, in: list) else { return nil }
        return pullRequest.reviewRequestedAt ?? pullRequest.updatedAt
    }
}

struct PullRequestRow: View {
    let pullRequest: PullRequestSummary
    let showsAuthor: Bool
    /// Off where every PR is awaiting the viewer's review, so saying a review is required or
    /// asked for would say nothing.
    let showsReviewRequired: Bool
    let isSelfReviewed: Bool
    /// Set on a PR whose request for review is old enough to be hidden by default.
    var staleRequestedAt: Date? = nil
    /// The viewer's approval or request for changes, set where that's why the PR is listed.
    var verdict: ReviewState? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The repo and number lead, as that's how PRs get talked about; the owner is
            // secondary and is the first thing to truncate in a narrow column.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(repositoryName(pullRequest)) #\(pullRequest.number)")
                    .font(.headline.monospacedDigit())
                    .layoutPriority(1)
                StateBadge(pullRequest: pullRequest, showsOpen: false)
                ConflictsBadge(pullRequest: pullRequest)
                SelfReviewedBadge(isSelfReviewed: isSelfReviewed)
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
                if let verdict {
                    TimelineView(.everyMinute) { context in
                        ViewerVerdictBadge(verdict: verdict, detail: pullRequest.viewerVerdict, now: context.date)
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
                    TimelineView(.everyMinute) { _ in
                        Text("requested \(staleRequestedAt.formatted(.relative(presentation: .named)))")
                            .foregroundStyle(.tertiary)
                    }
                }
                TimelineView(.everyMinute) { _ in
                    Text(pullRequest.updatedAt.formatted(.relative(presentation: .named)))
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

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
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

/// The viewer's own approval or request for changes on a PR in To review, so the list reads as
/// what needs them apart from what waits to be merged or on its author. Its tooltip says when,
/// and whether the PR has changed since, where that's known.
struct ViewerVerdictBadge: View {
    let verdict: ReviewState
    /// Nil until the to-review check has said when and on which head.
    let detail: ViewerVerdict?
    /// What the tooltip's "N ago" is from.
    var now: Date = .now

    var body: some View {
        switch verdict {
        case .approved:
            Badge(text: "You approved", tint: .diffSuccess)
                .help("\(summary ?? "You approved this"); it's waiting to be merged")
        case .changesRequested:
            Badge(text: "You requested changes", tint: .diffDanger)
                .help("\(summary ?? "You requested changes"); it's waiting on its author")
        default:
            EmptyView()
        }
    }

    private var summary: String? {
        detail.flatMap { $0.state == verdict ? $0.summary(now: now) : nil }
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

/// Lets the snapshot run find the To review column's caption to click.
struct StaleRequestsToggleMarker: NSViewRepresentable {
    final class Marker: NSView {}

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) {}
}
