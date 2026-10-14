import Foundation
import Observation

/// The start screen's state: the two PR columns, kept fresh by `keepRefreshed`.
@Observable
@MainActor
public final class PullRequestListModel {
    /// Nil until the first load succeeds, and again after a failed refresh, so an error is never
    /// shown alongside lists that may be out of date.
    public private(set) var lists: PullRequestLists?
    public private(set) var error: String?
    public private(set) var isLoading = false
    public private(set) var lastRefreshed: Date?

    /// Where choosing a PR goes. The app opens it in the browser; a diff view can take over here.
    public var onOpen: @MainActor (PullRequestSummary) -> Void

    private let client: GitHubClient
    private let refreshInterval: Duration

    public init(
        client: GitHubClient = GitHubClient(),
        refreshInterval: Duration = .seconds(180),
        onOpen: @escaping @MainActor (PullRequestSummary) -> Void
    ) {
        self.client = client
        self.refreshInterval = refreshInterval
        self.onOpen = onOpen
    }

    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            lists = try await client.pullRequestLists()
            error = nil
            lastRefreshed = .now
        } catch {
            lists = nil
            self.error = error.localizedDescription
        }
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
