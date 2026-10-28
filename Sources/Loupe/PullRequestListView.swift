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
                        ListsSplit {
                            PullRequestColumn(title: "Mine", list: .mine, showsAuthor: false, showsClosed: showsClosed, model: model)
                        } trailing: {
                            ReviewColumn(showsClosed: showsClosed, model: model)
                        }
                    case .todo:
                        TodoListView(model: model)
                    }
                }
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        if model.needsCheckoutFolders {
                            CheckoutFoldersBanner(model: model)
                        }
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


/// Mine and To review side by side, divided where the viewer last dragged the divider between
/// them. It's kept as Mine's share of the width, so the split holds as the window resizes.
struct ListsSplit<Leading: View, Trailing: View>: View {
    @ViewBuilder let leading: Leading
    @ViewBuilder let trailing: Trailing
    @AppStorage("listsSplit") private var share = 0.5
    /// Mine's share when the drag under way began.
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width - 1
            HStack(spacing: 0) {
                leading
                    .frame(width: Self.clamped(width * share, in: width))
                Divider()
                    .overlay {
                        DividerGrip { moved in
                            let start = dragStart ?? share
                            dragStart = start
                            share = Self.clamped(width * start + moved, in: width) / width
                        } ended: {
                            dragStart = nil
                        }
                        .frame(width: Self.grabWidth)
                    }
                    // Over both lists, so either side of the line can be grabbed.
                    .zIndex(1)
                    // A slider to accessibility, which reads and moves the split as one.
                    .accessibilityRepresentation {
                        // Mine's share in whole percent.
                        Slider(value: Binding { (share * 100).rounded() } set: { share = Self.clamped(width * $0 / 100, in: width) / width }, in: 0...100, step: 1)
                            .accessibilityLabel("Divider between the lists")
                            .accessibilityIdentifier("lists-divider")
                    }
                trailing
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Narrow enough to give the other list most of the window, wide enough for a row's title.
    private static var minWidth: CGFloat { 280 }
    private static var grabWidth: CGFloat { 8 }

    private static func clamped(_ leadingWidth: CGFloat, in width: CGFloat) -> CGFloat {
        min(max(leadingWidth, minWidth), max(width - minWidth, minWidth))
    }
}


/// Where the lists' divider is grabbed: an AppKit view, so it shows the resize cursor and
/// follows a drag by its events' own positions.
struct DividerGrip: NSViewRepresentable {
    /// How far right the pointer has moved since the drag began, negative for left.
    let moved: (CGFloat) -> Void
    let ended: () -> Void

    func makeNSView(context: Context) -> Grip {
        let grip = Grip()
        updateNSView(grip, context: context)
        return grip
    }

    func updateNSView(_ grip: Grip, context: Context) {
        grip.moved = moved
        grip.ended = ended
    }

    final class Grip: NSView {
        var moved: (CGFloat) -> Void = { _ in }
        var ended: () -> Void = {}
        /// In the window, which stays put as the divider moves under the pointer.
        private var startX: CGFloat?

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: .resizeLeftRight)
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            startX = event.locationInWindow.x
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startX else { return }
            moved(event.locationInWindow.x - startX)
        }

        override func mouseUp(with event: NSEvent) {
            startX = nil
            ended()
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
/// Above the lists until the folders to search for checkouts are chosen, as on first launch,
/// since no diffs can be shown before then.
struct CheckoutFoldersBanner: View {
    let model: PullRequestListModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "folder.badge.questionmark").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Where are your checkouts?").font(.callout.weight(.semibold))
                Text("Diffs come from local git checkouts. Choose the folders they're in, and Loupe will look in each for one named after a pull request's repository.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Choose Folders…") {
                chooseCheckoutFolders(startingAt: nil) { try await model.chooseCheckoutFolders($0) }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("checkout-folders-banner")
    }
}

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
                    ListedRow(listed: listed, list: list, showsAuthor: showsAuthor, model: model)
                }
                .onKeyPress(.return) {
                    guard let pullRequest = pullRequests.first(where: { $0.id == selection }) else { return .ignored }
                    model.open(pullRequest)
                    return .handled
                }
            }
            let stale = model.staleCount(in: list, includingClosed: showsClosed)
            if stale > 0 {
                StaleToggle(count: stale, isShown: $showsStale)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// To review's PRs in one list, in a section for each stage of the viewer's review, so the
/// stages take only the room their PRs need.
struct ReviewColumn: View {
    let showsClosed: Bool
    let model: PullRequestListModel
    /// Moved with the arrow keys across the sections; Return opens it.
    @State private var selection: PullRequestSummary.ID?
    /// The stages whose PRs held back as stale are listed, for this session only.
    @State private var showingStale: Set<ReviewStage> = []

    var body: some View {
        let sections = ReviewStage.allCases.map { stage in
            (stage: stage, listing: model.listing(in: .toReview, stage: stage, includingClosed: showsClosed, includingStale: showingStale.contains(stage)))
        }
        List(selection: $selection) {
            ForEach(sections, id: \.stage) { section in
                // A plain row rather than a section header, which would stay pinned over the rows.
                Text("\(section.stage.title) (\(section.listing.count))")
                    .font(.headline)
                    .padding(.top, section.stage == ReviewStage.allCases.first ? 0 : 12)
                    .accessibilityAddTraits(.isHeader)
                if section.listing.isEmpty {
                    Text(model.isSearching ? "No matches" : "Nothing here")
                        .foregroundStyle(.secondary)
                }
                ForEach(section.listing) { listed in
                    ListedRow(listed: listed, list: .toReview, showsAuthor: true, model: model)
                }
                let stale = model.staleCount(in: .toReview, stage: section.stage, includingClosed: showsClosed)
                if stale > 0 {
                    StaleToggle(count: stale, isShown: Binding {
                        showingStale.contains(section.stage)
                    } set: { shown in
                        if shown { showingStale.insert(section.stage) } else { showingStale.remove(section.stage) }
                    })
                }
            }
        }
        .onKeyPress(.return) {
            let pullRequests = sections.flatMap { $0.listing.map(\.pullRequest) }
            guard let pullRequest = pullRequests.first(where: { $0.id == selection }) else { return .ignored }
            model.open(pullRequest)
            return .handled
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A listed PR's row, which opens it when clicked.
struct ListedRow: View {
    let listed: StackedPullRequest
    let list: PullRequestList
    let showsAuthor: Bool
    let model: PullRequestListModel

    var body: some View {
        let pullRequest = listed.pullRequest
        Button { model.open(pullRequest) } label: {
            PullRequestRow(pullRequest: pullRequest, showsAuthor: showsAuthor, showsReviewRequired: list != .toReview, selfReview: model.selfReview(of: pullRequest), staleRequestedAt: staleRequestedAt(of: pullRequest), verdict: model.verdict(on: pullRequest, in: list), stackedOn: listed.parent, reviewMark: model.reviewMark(on: pullRequest, in: list))
                .padding(.leading, CGFloat(listed.depth) * Self.stackIndent)
        }
        .buttonStyle(.plain)
        .contextMenu { CheckoutMenu(repository: pullRequest.repository, model: model) }
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

/// Says how many PRs are hidden for being over a month old, and lists or hides them when clicked.
struct StaleToggle: View {
    let count: Int
    @Binding var isShown: Bool

    var body: some View {
        Button(isShown ? "Hide \(count) older than a month" : "\(count) older than a month hidden") {
            isShown.toggle()
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .background(StaleToggleMarker())
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
/// that out. On an open PR's tab, resting on it lists the conflicting files.
struct ConflictsBadge: View {
    let pullRequest: PullRequestSummary
    var tab: PullRequestTab? = nil

    var body: some View {
        if pullRequest.mergeable == .conflicting {
            if let tab {
                Badge(text: "Conflicts", tint: .diffDanger)
                    .background(HoverPopoverAnchor(content: ConflictsPopoverContent(tab: tab)))
                    .accessibilityIdentifier("conflicts-badge")
            } else {
                Badge(text: "Conflicts", tint: .diffDanger)
                    .help("This branch has conflicts that must be resolved before it can be merged")
            }
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


private extension ReviewStage {
    var title: String {
        switch self {
        case .toReview: "To review"
        case .reviewing: "Reviewing"
        case .approved: "Approved"
        }
    }
}
