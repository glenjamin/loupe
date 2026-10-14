import LoupeGitHub
import SwiftUI

/// The start screen: the user's own open PRs beside the ones waiting on their review.
struct PullRequestListView: View {
    let model: PullRequestListModel

    var body: some View {
        Group {
            if let lists = model.lists {
                // Re-render each minute so the "updated N ago" labels don't go stale between refreshes.
                TimelineView(.everyMinute) { _ in
                    HStack(spacing: 0) {
                        PullRequestColumn(title: "Mine", page: lists.mine, showsAuthor: false, open: model.open)
                        Divider()
                        PullRequestColumn(title: "To review", page: lists.toReview, showsAuthor: true, open: model.open)
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
                } else if let lastRefreshed = model.lastRefreshed {
                    TimelineView(.everyMinute) { _ in
                        Text("Updated \(lastRefreshed.formatted(.relative(presentation: .named)))")
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
    }
}

struct PullRequestColumn: View {
    let title: String
    let page: PullRequestPage
    let showsAuthor: Bool
    let open: (PullRequestSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(heading)
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            if page.pullRequests.isEmpty {
                Text("Nothing here")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(page.pullRequests) { pullRequest in
                    Button { open(pullRequest) } label: {
                        PullRequestRow(pullRequest: pullRequest, showsAuthor: showsAuthor)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var heading: String {
        let shown = page.pullRequests.count
        return shown < page.totalCount ? "\(title) (\(shown) of \(page.totalCount))" : "\(title) (\(shown))"
    }
}

struct PullRequestRow: View {
    let pullRequest: PullRequestSummary
    let showsAuthor: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                if pullRequest.isDraft {
                    Text("Draft")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                Text(pullRequest.title).lineLimit(2)
            }
            HStack(spacing: 8) {
                Text("\(pullRequest.repository)#\(pullRequest.number)")
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
