import AppKit
import LoupeInbox
import LoupeModel
import SwiftUI

/// Whether the start screen shows the two lists side by side, or one list of what to do next.
enum ListMode: String {
    case lists
    case todo

    /// Where the choice is remembered.
    static let key = "pullRequestListMode"
}

/// The lists as one list in sections: what awaits the viewer's review, their own PRs nearest
/// done first, and, folded away, their PRs that wait on others. Each row says why it's there.
struct TodoListView: View {
    let model: PullRequestListModel
    /// Moved with the arrow keys; Return opens it.
    @State private var selection: PullRequestSummary.ID?
    /// Lists the PRs that wait on others, for this session only.
    @State private var showsWaiting = false
    /// The stacks whose PRs above the bottom one are listed, by the bottom PR's id.
    @State private var expandedStacks: Set<String> = []

    var body: some View {
        let todo = model.todo()
        let review = rows(todo.review)
        let yours = rows(todo.yours)
        let waiting = showsWaiting ? rows(todo.waiting) : []
        if todo.isEmpty {
            Text("Nothing to do")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                if !review.isEmpty {
                    Section {
                        ForEach(review) { row($0) }
                    } header: {
                        sectionTitle("Review", count: todo.review.count)
                    }
                }
                if !yours.isEmpty {
                    Section {
                        ForEach(yours) { row($0) }
                    } header: {
                        sectionTitle("Yours", count: todo.yours.count)
                    }
                }
                if !todo.waiting.isEmpty {
                    Section {
                        ForEach(waiting) { row($0) }
                    } header: {
                        Button {
                            showsWaiting.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "chevron.right")
                                    .rotationEffect(.degrees(showsWaiting ? 90 : 0))
                                    .font(.caption.weight(.semibold))
                                sectionTitle("Waiting on others", count: todo.waiting.count)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .background(SnapshotClickMarker(name: "waiting"))
                        .help(showsWaiting ? "Hide your PRs that wait on reviewers or checks" : "Show your PRs that wait on reviewers or checks")
                    }
                }
            }
            .onKeyPress(.return) {
                guard let pullRequest = (review + yours + waiting).first(where: { $0.id == selection })?.pullRequest else { return .ignored }
                model.open(pullRequest)
                return .handled
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        Text("\(title) (\(count))")
            .font(.headline)
            .foregroundStyle(.primary)
    }

    private func row(_ row: TodoRow) -> some View {
        let pullRequest = row.pullRequest
        let isReview = row.list == .toReview
        return HStack(alignment: .center, spacing: 8) {
            Button { model.open(pullRequest) } label: {
                PullRequestRow(
                    pullRequest: pullRequest, showsAuthor: isReview, showsReviewRequired: !isReview, isSelfReviewed: model.isSelfReviewed(pullRequest),
                    verdict: model.verdict(on: pullRequest, in: row.list), stackedOn: row.parent, reviewMark: model.reviewMark(on: pullRequest, in: row.list),
                    reason: row.reason
                )
            }
            .buttonStyle(.plain)
            if let stack = row.stackAbove {
                let expanded = expandedStacks.contains(row.id)
                Button(expanded ? "Hide \(stack) stacked" : "+\(stack) stacked") {
                    if expanded { expandedStacks.remove(row.id) } else { expandedStacks.insert(row.id) }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .background(SnapshotClickMarker(name: "stack"))
                .help(expanded ? "Hide the PRs stacked on this one" : "Show the PRs stacked on this one")
            }
        }
        .padding(.leading, CGFloat(row.depth) * Self.stackIndent)
        .contextMenu { CheckoutMenu(repository: pullRequest.repository, model: model) }
    }

    /// Each item's row, then the rows of its stack above it if they're shown.
    private func rows(_ items: [TodoItem]) -> [TodoRow] {
        items.flatMap { item in
            let bottom = TodoRow(pullRequest: item.pullRequest, list: item.list, reason: item.reason, parent: item.parent, depth: 0, stackAbove: item.stacked.isEmpty ? nil : item.stacked.count)
            guard expandedStacks.contains(item.id) else { return [bottom] }
            return [bottom] + item.stacked.map { TodoRow(pullRequest: $0.pullRequest, list: item.list, reason: nil, parent: $0.parent, depth: $0.depth, stackAbove: nil) }
        }
    }

    /// How far each PR in a stack is stepped in from the one below it, as in the lists.
    private static let stackIndent: CGFloat = 16
}

/// A row as the TODO view draws it.
private struct TodoRow: Identifiable {
    let pullRequest: PullRequestSummary
    let list: PullRequestList
    /// Nil on a stacked PR shown under its stack's row, which the stack's reason covers.
    let reason: TodoReason?
    let parent: PullRequestSummary?
    let depth: Int
    /// How many of the viewer's PRs are stacked above this one, on a stack's row.
    let stackAbove: Int?

    var id: String { pullRequest.id }
}

/// Why a PR is where it is in the TODO view, coloured by how it stands: green when approved,
/// red when something needs fixing, the attention colour when it needs a look, grey when
/// it waits.
struct TodoReasonBadge: View {
    let reason: TodoReason

    var body: some View {
        Badge(text: reason.label, tint: tint)
    }

    private var tint: Color {
        switch reason {
        case .readyToMerge, .approvedChecksRunning, .approvedBehind, .approvedChecking, .approvedBlocked: .diffSuccess
        case .checksFailing, .conflicts, .changesRequested: .diffDanger
        case .reviewRequested, .reRequested, .updatedSinceReview, .requestReviewers: .diffAttention
        case .draft: .primary
        case .waitingOnReview, .pushedSinceChangesRequested: .secondary
        }
    }
}

/// Lets the snapshot run find a control to click by name.
struct SnapshotClickMarker: NSViewRepresentable {
    let name: String

    final class Marker: NSView {
        var name = ""
    }

    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ view: Marker, context: Context) { view.name = name }
}
