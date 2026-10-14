import AppKit
import LoupeInbox
import LoupeModel
import SwiftUI

/// The start screen: the user's own open PRs beside the ones waiting on their review.
struct PullRequestListView: View {
    let model: PullRequestListModel

    var body: some View {
        Group {
            if model.hasStoredLists {
                // Re-render each minute so the "N ago" labels don't go stale between refreshes.
                TimelineView(.everyMinute) { _ in
                    HStack(spacing: 0) {
                        PullRequestColumn(title: "Mine", pullRequests: model.pullRequests(in: .mine), showsAuthor: false, open: model.open)
                        Divider()
                        PullRequestColumn(title: "To review", pullRequests: model.pullRequests(in: .toReview), showsAuthor: true, open: model.open)
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
        .toolbar {
            ToolbarItemGroup {
                if model.isLoading {
                    ProgressView().controlSize(.small)
                }
                if let lastRefreshed = model.lastRefreshed {
                    TimelineView(.everyMinute) { _ in
                        Text("Refreshed \(lastRefreshed.formatted(.relative(presentation: .named)))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(model.isLoading)
            }
        }
        .task { await model.keepRefreshed() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshIfStale() }
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
    let pullRequests: [PullRequestSummary]
    let showsAuthor: Bool
    let open: (PullRequestSummary) -> Void

    var body: some View {
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
                List(pullRequests) { pullRequest in
                    Button { open(pullRequest) } label: {
                        PullRequestRow(pullRequest: pullRequest, showsAuthor: showsAuthor)
                    }
                    .buttonStyle(.plain)
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
                Text("\(repositoryName) #\(pullRequest.number)")
                    .font(.headline.monospacedDigit())
                    .layoutPriority(1)
                if pullRequest.isDraft {
                    Text("Draft")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
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
                    ChecksIcon(state: checks)
                }
                Spacer(minLength: 0)
                Text(pullRequest.updatedAt.formatted(.relative(presentation: .named)))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help("\(pullRequest.headRefName) → \(pullRequest.baseRefName)\n\(pullRequest.url.absoluteString)")
    }

    private var owner: String {
        pullRequest.repository.split(separator: "/").first.map(String.init) ?? ""
    }

    private var repositoryName: String {
        pullRequest.repository.split(separator: "/").last.map(String.init) ?? pullRequest.repository
    }
}

struct ReviewDecisionLabel: View {
    let decision: ReviewDecision

    var body: some View {
        switch decision {
        case .approved: Text("Approved").foregroundStyle(.green)
        case .changesRequested: Text("Changes requested").foregroundStyle(.red)
        case .reviewRequired: Text("Review required")
        case .unknown: EmptyView()
        }
    }
}

struct ChecksIcon: View {
    let state: CheckState

    var body: some View {
        switch state {
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).help("Checks passed")
        case .failure, .error:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red).help("Checks failed")
        case .pending, .expected:
            Image(systemName: "clock.fill").foregroundStyle(.orange).help("Checks running")
        case .unknown:
            Image(systemName: "questionmark.circle").help("Unknown check state")
        }
    }
}
