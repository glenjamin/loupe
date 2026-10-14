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
                // Re-render each minute so the "N ago" labels don't go stale between refreshes.
                TimelineView(.everyMinute) { _ in
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
                Text(headline).font(.callout.weight(.semibold))
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

    var body: some View {
        let pullRequests = model.pullRequests(in: list, includingClosed: showsClosed)
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
                        PullRequestRow(pullRequest: pullRequest, showsAuthor: showsAuthor)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PullRequestRow: View {
    let pullRequest: PullRequestSummary
    let showsAuthor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // The repo and number lead, as that's how PRs get talked about; the owner is
            // secondary and is the first thing to truncate in a narrow column.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(repositoryName(pullRequest)) #\(pullRequest.number)")
                    .font(.headline.monospacedDigit())
                    .layoutPriority(1)
                StateBadge(pullRequest: pullRequest, showsOpen: false)
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
                if let decision = pullRequest.reviewDecision {
                    ReviewDecisionLabel(decision: decision)
                }
                if let checks = pullRequest.checks {
                    ChecksIcon(state: checks, contexts: pullRequest.checkContexts)
                }
                Spacer(minLength: 0)
                Text(pullRequest.updatedAt.formatted(.relative(presentation: .named)))
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

struct ReviewDecisionLabel: View {
    let decision: ReviewDecision

    var body: some View {
        switch decision {
        case .approved: Text("Approved").foregroundStyle(.diffSuccess)
        case .changesRequested: Text("Changes requested").foregroundStyle(.diffDanger)
        case .reviewRequired: Text("Review required")
        case .unknown: EmptyView()
        }
    }
}

/// The head commit's overall check state as a bare glyph; hovering lists each check.
struct ChecksIcon: View {
    let state: CheckState
    /// Empty until looked up, when the tooltip only names the overall state.
    let contexts: [CheckContext]

    var body: some View {
        glyph
            .fontWeight(.semibold)
            .help(contexts.tooltip ?? fallbackHelp)
    }

    @ViewBuilder private var glyph: some View {
        switch state {
        case .success: Image(systemName: "checkmark").foregroundStyle(.diffSuccess)
        case .failure, .error: Image(systemName: "xmark").foregroundStyle(.diffDanger)
        case .pending, .expected: Image(systemName: "clock").foregroundStyle(.orange)
        case .unknown: Image(systemName: "questionmark").foregroundStyle(.secondary)
        }
    }

    private var fallbackHelp: String {
        switch state {
        case .success: "Checks passed"
        case .failure, .error: "Checks failed"
        case .pending, .expected: "Checks running"
        case .unknown: "Unknown check state"
        }
    }
}
