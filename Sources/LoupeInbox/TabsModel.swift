import Foundation
import LoupeGit
import LoupeGitHub
import LoupeModel
import LoupeStore
import Observation

/// The PRs open as tabs beside the PR lists, and which of them is shown. Both are stored, so the
/// tabs come back next launch.
@Observable
@MainActor
public final class TabsModel {
    public let lists: PullRequestListModel
    /// The strip's tabs after the lists, in the order they were opened: PRs, and links to PRs
    /// still being looked up.
    public private(set) var items: [TabItem] = []
    /// Nil when the PR lists are shown.
    public private(set) var selected: String?
    /// Shows the PR's tab; set by the app.
    public var show: @MainActor (String) -> Void = { _ in }
    /// How the open PRs learn they've changed on GitHub.
    public private(set) var changeSignal = ChangeSignal.notifications

    private let store: PullRequestStore
    private let differ: PullRequestDiffer
    private let client: GitHubClient
    /// Who could review in each repo, fetched once a run and shared by the tabs.
    private let candidates: ReviewerCandidates
    private let notifications: GitHubNotifications
    private let fallbackInterval: Duration
    /// From the last notifications poll that found changes, to ask only for newer ones.
    private var notificationsModified: String?
    /// How the tabs wait for a burst of changes to settle; tests pass one they control.
    private let sleep: @Sendable (Duration) async throws -> Void
    /// How the shown PR waits for the selection to settle before it's checked; tests pass one
    /// they control.
    private let showDelay: @Sendable (Duration) async throws -> Void
    /// The time, for how recently each PR was checked; tests pass one they control.
    private let now: @Sendable () -> ContinuousClock.Instant
    /// The pending check of the shown PR, replaced whenever the selection changes.
    private var shownCheck: Task<Void, Never>?
    /// When each open PR was last checked for changes, so showing it again soon after doesn't
    /// ask GitHub again.
    private var lastChecked: [String: ContinuousClock.Instant] = [:]

    /// Restores the PRs stored by the previous run, and makes choosing a PR in `lists` open it.
    /// `fallbackInterval` is how often open PRs are checked when notifications can't say.
    public init(
        lists: PullRequestListModel,
        store: PullRequestStore,
        differ: PullRequestDiffer = PullRequestDiffer(),
        client: GitHubClient = GitHubClient(),
        notifications: GitHubNotifications = GitHubNotifications(),
        fallbackInterval: Duration = .seconds(60),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        showDelay: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }
    ) {
        self.lists = lists
        self.store = store
        self.differ = differ
        self.client = client
        candidates = ReviewerCandidates(client: client)
        self.notifications = notifications
        self.fallbackInterval = fallbackInterval
        self.sleep = sleep
        self.showDelay = showDelay
        self.now = now
        do {
            let saved = try store.openTabs()
            items = saved.pullRequests.map { .pullRequest(makeTab($0)) }
            selected = saved.selected
        } catch {
            log("Couldn't restore open tabs: \(error)")
        }
        lists.onOpen = { [weak self] in self?.open($0) }
        lists.onCheckoutFoldersChosen = { [weak self] in await self?.retryMissingCheckouts() }
    }

    /// The open PRs, in the order they were opened, leaving out links still being looked up.
    public var tabs: [PullRequestTab] {
        items.compactMap(\.pullRequestTab)
    }

    public func tab(id: String) -> PullRequestTab? {
        tabs.first { $0.id == id }
    }

    public func item(id: String) -> TabItem? {
        items.first { $0.id == id }
    }

    /// Opens the PR, or focuses it if it's already open. A tab waiting on a link to it becomes
    /// its tab in place.
    public func open(_ pullRequest: PullRequestSummary) {
        if tab(id: pullRequest.id) == nil {
            let tab = TabItem.pullRequest(makeTab(pullRequest))
            if let index = items.firstIndex(where: { $0.pending.map { $0.link.names(pullRequest) } ?? false }) {
                items[index] = tab
            } else {
                items.append(tab)
            }
        }
        reveal(pullRequest.id)
    }

    /// Opens the PR a link names, or focuses its tab, then lands on what in it the link points
    /// at. A stored PR opens at once. Any other gets a tab from the link alone at once, while
    /// it's looked up on GitHub and stored like any listed PR, then becomes the PR's tab in
    /// place, landing on what the latest link to it pointed at; if it can't be found the tab
    /// says why. Returns the lookup and landing, for whoever wants to wait for them.
    @discardableResult
    public func open(_ link: PullRequestLink) -> Task<Void, Never>? {
        if let known = tabs.map(\.pullRequest).first(where: link.names) ?? lists.pullRequest(repository: link.repository, number: link.number) {
            open(known)
            return land(on: link.target, inTab: known.id)
        }
        if let pending = items.lazy.compactMap(\.pending).first(where: { $0.link.names(link) }) {
            pending.target = link.target
            reveal(pending.id)
            return retry(pending)
        }
        let pending = PendingTab(link: link)
        items.append(.pending(pending))
        reveal(pending.id)
        return startLookUp(pending)
    }

    /// Looks the link's PR up again after it failed; while a lookup is underway, returns that.
    @discardableResult
    public func retry(_ pending: PendingTab) -> Task<Void, Never> {
        if pending.error == nil, let lookup = pending.lookup { return lookup }
        return startLookUp(pending)
    }

    /// Records which PR is shown, or nil for the lists.
    public func select(_ id: String?) {
        guard id.map({ item(id: $0) != nil }) ?? true, id != selected else { return }
        selected = id
        save()
        checkShownForChanges()
    }

    /// Checks the shown PR and its merge state on GitHub once the selection settles, unless it
    /// was checked moments ago; run whenever a PR is shown and when the app comes to the front.
    /// The viewer has just come to it, so new commits are reloaded rather than offered: at once
    /// when they came while the viewer was away, otherwise when the check finds them.
    public func checkShownForChanges() {
        shownCheck?.cancel()
        shownCheck = nil
        guard let id = selected, let shown = tab(id: id) else { return }
        if shown.reloadsOnReturn {
            // Not cancelled by moving on, so the reload is ready when the viewer comes back.
            catchUp(shown)
            return
        }
        shownCheck = Task { [weak self, showDelay] in
            do { try await showDelay(Self.showSettle) } catch { return }
            guard let self, !Task.isCancelled, selected == id else { return }
            if let last = lastChecked[id], now() - last < Self.recheckInterval { return }
            await catchUp(shown).value
        }
    }

    /// Shows the item `offset` places along from the shown one, the lists coming before the first
    /// PR and after the last.
    public func selectAdjacent(_ offset: Int) {
        let order = [nil] + items.map(\.id)
        let position = order.firstIndex(of: selected) ?? 0
        select(order[((position + offset) % order.count + order.count) % order.count])
    }

    /// Forgets the PR, as its tab has closed. Closing the shown tab shows the one that took its
    /// place, or the one before it when it was last, as browsers do.
    public func close(_ id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.remove(at: index)
        if selected == id {
            selected = items.isEmpty ? nil : items[min(index, items.count - 1)].id
            checkShownForChanges()
        }
        save()
    }

    /// Forgets every open PR, leaving the lists shown.
    public func closeAll() {
        items = []
        selected = nil
        save()
        checkShownForChanges()
    }

    /// One round of watching the open PRs for changes on GitHub: polls notifications and checks
    /// the open PRs they name, or checks every open PR when notifications can't be read. Returns
    /// how long to wait before the next round, never sooner than GitHub asks.
    public func watchForChanges() async -> Duration {
        if changeSignal == .notifications {
            do {
                let poll = try await notifications.poll(ifModifiedSince: notificationsModified)
                if case let .changed(named, lastModified) = poll.outcome {
                    notificationsModified = lastModified
                    // An older unread notification on an open PR costs only a cheap check.
                    let named = Set(named.map { PullRequestReference(repository: $0.repository.lowercased(), number: $0.number) })
                    await checkForChanges(to: tabs.filter { named.contains($0.pullRequest.reference) })
                }
                return poll.interval
            } catch let GitHubError.http(status, _) where [403, 404].contains(status) {
                // The token can't read notifications, which won't change while the app runs.
                changeSignal = .timer
            } catch {
                log("Couldn't poll notifications, checking open PRs directly: \(error.localizedDescription)")
            }
        }
        await checkForChanges(to: tabs)
        return fallbackInterval
    }

    /// Watches the open PRs for changes until the calling task is cancelled.
    public func keepWatchingForChanges() async {
        while !Task.isCancelled {
            let delay = await watchForChanges()
            try? await Task.sleep(for: delay)
        }
    }

    /// Follows the checks on the merge commits of the open PRs merged lately until they finish,
    /// sooner than the lists' refresh would, until the calling task is cancelled.
    public func keepWatchingMergeCommits() async {
        while !Task.isCancelled {
            await watchMergeCommits()
            try? await Task.sleep(for: Self.mergeCommitPollInterval)
        }
    }

    /// One round of following merge commits' checks: looks up the open PRs whose merge
    /// commit's checks haven't finished, if any.
    public func watchMergeCommits() async {
        let ids = tabs.map(\.pullRequest).filter(lists.awaitsMergeCommitChecks).map(\.id)
        do {
            try await lists.checkStatuses(of: ids)
        } catch {
            log("Couldn't look up the merge commits' checks of open PRs: \(error.localizedDescription)")
        }
    }

    /// How often the open PRs' merge commits' checks are looked up while they run: often enough
    /// that a job finishing shows soon after, as it does on GitHub.
    static let mergeCommitPollInterval = Duration.seconds(15)

    /// Looks up the PRs, then their checks and merge state, which the lookup leaves out and
    /// which an approval or a push can change, so the merge box doesn't wait for the lists.
    private func checkForChanges(to tabs: [PullRequestTab]) async {
        let checked = now()
        for tab in tabs { lastChecked[tab.id] = checked }
        do {
            let ids = tabs.map(\.id)
            try await lists.checkForChanges(to: ids)
            try await lists.checkStatuses(of: ids)
            for tab in tabs { tab.checkError = nil }
        } catch {
            for tab in tabs { tab.checkError = error.localizedDescription }
            log("Couldn't check open PRs for changes: \(error.localizedDescription)")
        }
    }

    /// Checks the PR the viewer has just come to, reloading its diff if it has new commits.
    @discardableResult
    private func catchUp(_ tab: PullRequestTab) -> Task<Void, Never> {
        tab.catchUp { [weak self] in await self?.checkForChanges(to: [tab]) }
    }

    /// How long the selection must stay put before the shown PR is checked, so flicking through
    /// tabs checks only the one landed on.
    private static let showSettle = Duration.milliseconds(300)
    /// How soon a PR checked once can be checked again on being shown.
    private static let recheckInterval = Duration.seconds(10)

    /// Shows the tab with `id`, already among the items.
    private func reveal(_ id: String) {
        selected = id
        save()
        show(id)
        checkShownForChanges()
    }

    private func startLookUp(_ pending: PendingTab) -> Task<Void, Never> {
        pending.error = nil
        let lookup = Task { await lookUp(pending) }
        pending.lookup = lookup
        return lookup
    }

    /// Finds the link's PR on GitHub and puts its tab where the link's was, unless that has
    /// closed meanwhile; otherwise says on the link's tab why it can't be opened.
    private func lookUp(_ pending: PendingTab) async {
        let link = pending.link
        do {
            guard let found = try await lists.lookUpPullRequest(repository: link.repository, number: link.number) else {
                log("No pull request \(link.repository)#\(link.number) on GitHub, or none visible")
                pending.error = "GitHub has no pull request \(link.repository) #\(link.number), or none you can see."
                return
            }
            guard item(id: pending.id) != nil else { return }
            try await store.addOpenTab(found)
            place(found, replacing: pending)
            let landing = land(on: pending.target, inTab: found.id)
            // Only now, as what's stacked with a PR is kept while it's open in a tab or listed.
            await lists.lookUpStacks(around: [found])
            await landing?.value
        } catch {
            log("Couldn't look up \(link.repository)#\(link.number): \(error.localizedDescription)")
            pending.error = error.localizedDescription
        }
    }

    /// Swaps the link's tab for the PR's, in the same place and shown if it was. Saved either
    /// way, so the stored tabs follow the strip even if the link's tab has just closed.
    private func place(_ found: PullRequestSummary, replacing pending: PendingTab) {
        guard let index = items.firstIndex(where: { $0.id == pending.id }) else { return save() }
        let wasShown = selected == pending.id
        if tab(id: found.id) == nil {
            items[index] = .pullRequest(makeTab(found))
        } else {
            // Already open, as when the link named the repo by an old name.
            items.remove(at: index)
        }
        if wasShown {
            reveal(found.id)
        } else {
            save()
        }
    }

    /// Lands on what a link pointed at in the PR's open tab, if it pointed at anything.
    private func land(on target: PullRequestLink.Target?, inTab id: String) -> Task<Void, Never>? {
        guard let target, let tab = tab(id: id) else { return nil }
        return Task { await tab.land(on: target) }
    }

    private func makeTab(_ pullRequest: PullRequestSummary) -> PullRequestTab {
        let tab = PullRequestTab(opened: pullRequest, lists: lists, store: store, differ: differ, client: client, candidates: candidates, sleep: sleep)
        tab.linkOpener = { [weak self] link in await self?.open(link)?.value }
        return tab
    }

    /// Only PRs' tabs are stored: a link still being looked up has no PR to store yet, so the
    /// lists are stored as shown while it is.
    private func save() {
        do {
            try store.saveOpenTabs(tabs.map(\.id), selected: selected.flatMap(tab(id:))?.id)
        } catch {
            log("Couldn't save open tabs: \(error)")
        }
    }

    /// Produces the diff again in each tab that found no checkout, as new folders may hold it.
    private func retryMissingCheckouts() async {
        await withDiscardingTaskGroup { group in
            for tab in tabs {
                guard case .noCheckout = tab.phase else { continue }
                group.addTask { await tab.retry() }
            }
        }
    }
}

/// One of the strip's tabs: an open PR, or a link to one still being looked up.
@MainActor
public enum TabItem: Identifiable {
    case pullRequest(PullRequestTab)
    case pending(PendingTab)

    public nonisolated var id: String {
        switch self {
        case let .pullRequest(tab): tab.id
        case let .pending(pending): pending.id
        }
    }

    /// `repo #number`.
    public var title: String {
        switch self {
        case let .pullRequest(tab): tab.title
        case let .pending(pending): pending.title
        }
    }

    /// The PR's page on github.com.
    public var url: URL {
        switch self {
        case let .pullRequest(tab): tab.pullRequest.url
        case let .pending(pending): pending.url
        }
    }

    public var pullRequestTab: PullRequestTab? {
        if case let .pullRequest(tab) = self { tab } else { nil }
    }

    public var pending: PendingTab? {
        if case let .pending(pending) = self { pending } else { nil }
    }
}

/// How open PRs learn they've changed on GitHub.
public enum ChangeSignal: Sendable, Equatable {
    /// Polling the user's notifications, and checking the open PRs they name.
    case notifications
    /// Notifications can't be read, so every open PR is checked on a timer.
    case timer
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

private extension PullRequestLink {
    /// Repo names aren't case-sensitive, as on GitHub.
    func names(_ pullRequest: PullRequestSummary) -> Bool {
        pullRequest.number == number && pullRequest.repository.caseInsensitiveCompare(repository) == .orderedSame
    }

    func names(_ other: PullRequestLink) -> Bool {
        other.number == number && other.repository.caseInsensitiveCompare(repository) == .orderedSame
    }
}

private extension PullRequestSummary {
    /// Lowercased, as GitHub's repo names aren't case-sensitive.
    var reference: PullRequestReference {
        PullRequestReference(repository: repository.lowercased(), number: number)
    }
}
