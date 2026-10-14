import Foundation
import LoupeGit
import LoupeGitHub
import LoupeModel
import LoupeStore
import Observation

/// The PRs open in their own windows, which the app groups as native window tabs, and which of
/// them was frontmost. Both are stored, so the windows come back next launch.
@Observable
@MainActor
public final class TabsModel {
    public let lists: PullRequestListModel
    /// In the order they were opened.
    public private(set) var tabs: [PullRequestTab] = []
    /// Nil when the PR lists were frontmost.
    public private(set) var selected: String?
    /// Brings the PR's window forward, opening it if it has none; set by the app.
    public var show: @MainActor (String) -> Void = { _ in }
    /// How the open PRs learn they've changed on GitHub.
    public private(set) var changeSignal = ChangeSignal.notifications

    private let store: PullRequestStore
    private let differ: PullRequestDiffer
    private let notifications: GitHubNotifications
    private let fallbackInterval: Duration
    /// From the last notifications poll that found changes, to ask only for newer ones.
    private var notificationsModified: String?

    /// Restores the PRs stored by the previous run, and makes choosing a PR in `lists` open it.
    /// `fallbackInterval` is how often open PRs are checked when notifications can't say.
    public init(
        lists: PullRequestListModel,
        store: PullRequestStore,
        differ: PullRequestDiffer = PullRequestDiffer(),
        notifications: GitHubNotifications = GitHubNotifications(),
        fallbackInterval: Duration = .seconds(60)
    ) {
        self.lists = lists
        self.store = store
        self.differ = differ
        self.notifications = notifications
        self.fallbackInterval = fallbackInterval
        do {
            let saved = try store.openTabs()
            tabs = saved.pullRequests.map(makeTab)
            selected = saved.selected
        } catch {
            log("Couldn't restore open tabs: \(error)")
        }
        lists.onOpen = { [weak self] in self?.open($0) }
    }

    public func tab(id: String) -> PullRequestTab? {
        tabs.first { $0.id == id }
    }

    /// Opens the PR, or focuses it if it's already open.
    public func open(_ pullRequest: PullRequestSummary) {
        if tab(id: pullRequest.id) == nil {
            tabs.append(makeTab(pullRequest))
        }
        selected = pullRequest.id
        save()
        show(pullRequest.id)
    }

    /// Records which PR is frontmost, or nil for the lists.
    public func select(_ id: String?) {
        guard id.map({ tab(id: $0) != nil }) ?? true, id != selected else { return }
        selected = id
        save()
    }

    /// Forgets the PR, as its window has closed.
    public func close(_ id: String) {
        tabs.removeAll { $0.id == id }
        if selected == id { selected = nil }
        save()
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

    private func checkForChanges(to tabs: [PullRequestTab]) async {
        do {
            try await lists.checkForChanges(to: tabs.map(\.id))
        } catch {
            log("Couldn't check open PRs for changes: \(error.localizedDescription)")
        }
    }

    private func makeTab(_ pullRequest: PullRequestSummary) -> PullRequestTab {
        PullRequestTab(opened: pullRequest, lists: lists, store: store, differ: differ)
    }

    private func save() {
        do {
            try store.saveOpenTabs(tabs.map(\.id), selected: selected)
        } catch {
            log("Couldn't save open tabs: \(error)")
        }
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

private extension PullRequestSummary {
    /// Lowercased, as GitHub's repo names aren't case-sensitive.
    var reference: PullRequestReference {
        PullRequestReference(repository: repository.lowercased(), number: number)
    }
}
