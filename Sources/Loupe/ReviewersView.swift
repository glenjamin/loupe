import LoupeInbox
import LoupeModel
import SwiftUI

/// On the viewer's own PR, its reviewers as GitHub's sidebar lists them, each with where their
/// review stands, and a button to ask more people. Kept to a few compact rows at the header's
/// right, with any more summed up.
struct ReviewersBlock: View {
    let tab: PullRequestTab
    let reviewers: [ReviewerStatus]
    @State private var asking = false

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if let error = tab.reviewRequestError, !asking {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.diffDanger)
                    .help(error)
            }
            if !reviewers.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(row) { cell($0) }
                        }
                    }
                }
            }
            Button("Request a review", systemImage: "person.badge.plus") { asking = true }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Request a review")
                .popover(isPresented: $asking, arrowEdge: .bottom) {
                    RequestReviewPopover(tab: tab)
                }
        }
        .font(.caption)
        .fixedSize()
        // Fetched ahead so the popover opens full; it retries and shows any failure itself.
        .task { try? await tab.fetchReviewerCandidates() }
    }

    /// Up to `columns` reviewers a row and `maxRows` rows, the last place going to a count of
    /// the rest when they don't all fit.
    private var rows: [[Cell]] {
        let capacity = Self.columns * Self.maxRows
        var cells = reviewers.map(Cell.reviewer)
        if cells.count > capacity {
            let hidden = Array(reviewers[(capacity - 1)...])
            cells = Array(cells.prefix(capacity - 1)) + [.more(hidden)]
        }
        return stride(from: 0, to: cells.count, by: Self.columns).map { Array(cells[$0..<min($0 + Self.columns, cells.count)]) }
    }

    @ViewBuilder
    private func cell(_ cell: Cell) -> some View {
        switch cell {
        case let .reviewer(status):
            ReviewerRow(status: status) {
                Task { await tab.requestReview(from: status.reviewer) }
            }
        case let .more(hidden):
            Text(verbatim: "+\(hidden.count) more")
                .foregroundStyle(.secondary)
                .help(hidden.map { "\($0.reviewer.displayName): \($0.state.label)" }.joined(separator: "\n"))
        }
    }

    private static let columns = 2
    private static let maxRows = 3

    private enum Cell: Identifiable {
        case reviewer(ReviewerStatus)
        case more([ReviewerStatus])

        var id: String {
            switch self {
            case let .reviewer(status): status.id
            case .more: "more"
            }
        }
    }
}

/// One reviewer: a quiet symbol for where their review stands, who they are, and for someone
/// who has reviewed, a button to ask them again.
private struct ReviewerRow: View {
    let status: ReviewerStatus
    let reRequest: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: status.state.symbol)
                .foregroundStyle(status.state.tint)
                .frame(width: 12)
                .help(status.state.label)
            if status.reviewer.kind == .team {
                Image(systemName: "person.2")
                    .foregroundStyle(.secondary)
            }
            Text(verbatim: status.reviewer.displayName)
                .lineLimit(1)
                .help(status.reviewer.name.map { "\($0) (\(status.reviewer.login))" } ?? status.reviewer.login)
            if status.canReRequest {
                Button("Re-request review", systemImage: "arrow.clockwise", action: reRequest)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .imageScale(.small)
                    .help("Re-request review")
            }
        }
    }
}

/// Filters the people and teams who could review as the viewer types, and asks the one chosen,
/// saying here if GitHub refuses.
private struct RequestReviewPopover: View {
    let tab: PullRequestTab
    @State private var text = ""
    @State private var fetchError: String?

    var body: some View {
        let candidates = tab.reviewerCandidates(matching: text)
        VStack(alignment: .leading, spacing: 8) {
            TextField("Search people and teams", text: $text)
                .textFieldStyle(.roundedBorder)
            if let error = tab.reviewRequestError ?? fetchError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.diffDanger)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            if let candidates, !candidates.isEmpty {
                List(candidates) { reviewer in
                    Button {
                        Task { await tab.requestReview(from: reviewer) }
                    } label: {
                        CandidateRow(reviewer: reviewer)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            } else {
                Text(candidates == nil && fetchError == nil ? "Searching…" : "No one found")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(10)
        .frame(width: 280, height: 320)
        // A no-op once fetched; after a failure, opening the popover again retries.
        .task {
            do {
                try await tab.fetchReviewerCandidates()
                fetchError = nil
            } catch {
                fetchError = "Couldn't find reviewers: \(error.localizedDescription)"
            }
        }
    }
}

private struct CandidateRow: View {
    let reviewer: Reviewer

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: reviewer.kind == .team ? "person.2" : "person")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(verbatim: reviewer.displayName)
            if reviewer.kind == .user, let name = reviewer.name {
                Text(verbatim: name)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

private extension ReviewerStatus.State {
    var symbol: String {
        switch self {
        case .requested: "clock"
        case .approved: "checkmark"
        case .changesRequested: "xmark"
        case .commented: "bubble"
        case .dismissed: "minus"
        }
    }

    var tint: Color {
        switch self {
        case .approved: .diffSuccess
        case .changesRequested: .diffDanger
        case .requested, .commented, .dismissed: .secondary
        }
    }

    var label: String {
        switch self {
        case .requested: "Awaiting review"
        case .approved: "Approved"
        case .changesRequested: "Requested changes"
        case .commented: "Commented"
        case .dismissed: "Review dismissed"
        }
    }
}
