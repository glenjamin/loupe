import Foundation
import LoupeGitHub
import LoupeModel
import LoupeStore
import Observation

/// The start screen's state: the two PR columns, shown from the local store straight away and
/// kept in step with GitHub by `keepRefreshed`.
@Observable
@MainActor
public final class PullRequestListModel {
    /// Why the last refresh failed. The stored lists stay on screen meanwhile.
    public private(set) var error: String?
    public private(set) var isLoading = false

    /// Where choosing a PR goes. The app opens it in the browser; a diff view can take over here.
    public var onOpen: @MainActor (PullRequestSummary) -> Void

    private var snapshot: PullRequestSnapshot
    private let client: GitHubClient
    private let store: PullRequestStore
    private let refreshInterval: Duration
    private let staleAfter: Duration

    public init(
        client: GitHubClient = GitHubClient(),
        store: PullRequestStore,
        refreshInterval: Duration = .seconds(180),
        staleAfter: Duration = .seconds(300),
        onOpen: @escaping @MainActor (PullRequestSummary) -> Void
    ) {
        self.client = client
        self.store = store
        self.refreshInterval = refreshInterval
        self.staleAfter = staleAfter
        self.onOpen = onOpen
        do {
            snapshot = try store.snapshot()
        } catch {
            snapshot = PullRequestSnapshot.empty
            self.error = error.localizedDescription
        }
    }

    /// Newest first.
    public func pullRequests(in list: PullRequestList) -> [PullRequestSummary] {
        snapshot[list]
    }

    /// Whether there's anything from GitHub to show yet, even if out of date.
    public var hasStoredLists: Bool {
        PullRequestList.allCases.contains { snapshot.refreshedAt($0) != nil }
    }

    /// When both lists were last confirmed against GitHub (the older of the two), or nil if either
    /// never has been.
    public var lastRefreshed: Date? {
        let dates = PullRequestList.allCases.map(snapshot.refreshedAt)
        return dates.contains(nil) ? nil : dates.compactMap(\.self).min()
    }

    /// Fetches each list in full and reconciles the store with it. A list that fails to load
    /// keeps its stored rows.
    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        var failures: [String] = []
        for list in PullRequestList.allCases {
            do {
                let pullRequests = try await client.pullRequests(in: list)
                snapshot = try await store.replace(list, with: pullRequests, refreshedAt: .now)
            } catch {
                let message = error.localizedDescription
                if !failures.contains(message) { failures.append(message) }
            }
        }
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// Refreshes unless the lists were refreshed recently, e.g. when the app comes back to the
    /// foreground.
    public func refreshIfStale() async {
        if let lastRefreshed, Date.now.timeIntervalSince(lastRefreshed) < staleAfter.timeInterval { return }
        await refresh()
    }

    /// Refreshes now and then periodically until the calling task is cancelled.
    public func keepRefreshed() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: refreshInterval)
        }
    }

    public func open(_ pullRequest: PullRequestSummary) {
        onOpen(pullRequest)
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
