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
/// done first, and, folded away, their PRs that wait on others, all recently active; then their
/// PRs quiet for over a month, and, folded away, over six months. Each row says why it's there.
struct TodoListView: View {
    let model: PullRequestListModel
    /// Moved with the arrow keys; Return opens it.
    @State private var selection: PullRequestSummary.ID?
    /// Lists the PRs that wait on others, for this session only.
    @State private var showsWaiting = false
    /// Lists the PRs quiet for over a month, for this session only.
    @State private var showsOverAMonth = true
    /// Lists the PRs quiet for over six months, for this session only.
    @State private var showsOverSixMonths = false
    /// The stacks whose PRs above the bottom one are listed, by the bottom PR's id.
    @State private var expandedStacks: Set<String> = []
    /// The list's width, which its rows take half of.
    @State private var width: CGFloat = 0

    var body: some View {
        let todo = model.todo()
        let review = rows(todo.review)
        let yours = rows(todo.yours)
        let waiting = showsWaiting ? rows(todo.waiting) : []
        let overAMonth = showsOverAMonth ? rows(todo.overAMonth) : []
        let overSixMonths = showsOverSixMonths ? rows(todo.overSixMonths) : []
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
                        foldingTitle("Waiting on others", count: todo.waiting.count, shows: $showsWaiting, marker: "waiting", what: "your PRs that wait on reviewers or checks")
                    }
                }
                if !todo.overAMonth.isEmpty {
                    Section {
                        ForEach(overAMonth) { row($0) }
                    } header: {
                        foldingTitle("Over a month", count: todo.overAMonth.count, shows: $showsOverAMonth, marker: "over-a-month", what: "your PRs quiet for over a month")
                    }
                }
                if !todo.overSixMonths.isEmpty {
                    Section {
                        ForEach(overSixMonths) { row($0) }
                    } header: {
                        foldingTitle("Over 6 months", count: todo.overSixMonths.count, shows: $showsOverSixMonths, marker: "over-6-months", what: "your PRs quiet for over six months")
                    }
                }
            }
            .onKeyPress(.return) {
                guard let pullRequest = (review + yours + waiting + overAMonth + overSixMonths).first(where: { $0.id == selection })?.pullRequest else { return .ignored }
                model.open(pullRequest)
                return .handled
            }
            // The scroll view spans the window, so it scrolls from anywhere; only its rows narrow.
            .safeAreaPadding(.horizontal, Self.sideMargin(in: width))
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }

    private func sectionTitle(_ title: String, count: Int) -> some View {
        Text("\(title) (\(count))")
            .font(.headline)
            .foregroundStyle(.primary)
    }

    /// A section's title with its count, which folds and unfolds the section when clicked.
    private func foldingTitle(_ title: String, count: Int, shows: Binding<Bool>, marker: String, what: String) -> some View {
        Button {
            shows.wrappedValue.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(shows.wrappedValue ? 90 : 0))
                    .font(.caption.weight(.semibold))
                sectionTitle(title, count: count)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(SnapshotClickMarker(name: marker))
        .help(shows.wrappedValue ? "Hide \(what)" : "Show \(what)")
    }

    private func row(_ row: TodoRow) -> some View {
        let pullRequest = row.pullRequest
        let isReview = row.list == .toReview
        let stack = row.stackAbove.map { count in
            StackDisclosure(count: count, isExpanded: expandedStacks.contains(row.id)) {
                if expandedStacks.contains(row.id) { expandedStacks.remove(row.id) } else { expandedStacks.insert(row.id) }
            }
        }
        return Button { model.open(pullRequest) } label: {
            PullRequestRow(
                pullRequest: pullRequest, showsAuthor: isReview, showsReviewRequired: !isReview, selfReview: model.selfReview(of: pullRequest),
                verdict: model.verdict(on: pullRequest, in: row.list), stackedOn: row.parent, reviewMark: model.reviewMark(on: pullRequest, in: row.list),
                reason: row.reason, stack: stack
            )
        }
        .buttonStyle(.plain)
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

    /// The rows take half the window, centred, as one column of full-width rows is hard to read
    /// across; never narrower than a row needs, nor wider than the window.
    private static func sideMargin(in width: CGFloat) -> CGFloat {
        let content = min(width, max(minimumContentWidth, width / 2))
        return (width - content) / 2
    }

    private static let minimumContentWidth: CGFloat = 420
}

/// The "+N stacked" control on a stack's row, showing or hiding the PRs stacked on it.
struct StackDisclosure: View {
    let count: Int
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 3) {
                Label {
                    Text(verbatim: "+\(count) stacked")
                } icon: {
                    Image(systemName: "square.stack.3d.up")
                }
                Image(systemName: "chevron.right")
                    .imageScale(.small)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.caption)
        .foregroundStyle(.secondary)
        .background(SnapshotClickMarker(name: "stack"))
        .help(isExpanded ? "Hide the PRs stacked on this one" : "Show the PRs stacked on this one")
    }
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
