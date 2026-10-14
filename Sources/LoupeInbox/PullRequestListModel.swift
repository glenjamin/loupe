import Foundation
import LoupeGit
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
    private var checkouts: [String: CheckoutStatus] = [:]
    private let client: GitHubClient
    private let checkoutResolver: CheckoutResolver
    private let store: PullRequestStore
    private let refreshInterval: Duration
    private let staleAfter: Duration

    public init(
        client: GitHubClient = GitHubClient(),
        store: PullRequestStore,
        refreshInterval: Duration = .seconds(180),
        staleAfter: Duration = .seconds(300),
        checkoutSearchRoots: [URL] = CheckoutResolver.defaultSearchRoots,
        onOpen: @escaping @MainActor (PullRequestSummary) -> Void
    ) {
        self.client = client
        self.store = store
        checkoutResolver = CheckoutResolver(store: store, searchRoots: checkoutSearchRoots)
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

    /// Nil until the repo's checkout has been looked for.
    public func checkout(for repository: String) -> CheckoutStatus? {
        checkouts[repository]
    }

    /// The directories searched for a repo's checkout, so a manual locate can start there.
    public var checkoutSearchRoots: [URL] {
        checkoutResolver.searchRoots
    }

    /// Fetches each list in full and reconciles the store with it, then finds the listed repos'
    /// checkouts. A list that fails to load keeps its stored rows.
    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        await refreshLists()
        isLoading = false
        await resolveCheckouts()
    }

    /// Records `directory` as the checkout of `repository`, if it's a git repo whose origin is that
    /// repo on GitHub; otherwise throws, saying why.
    public func locateCheckout(for repository: String, at directory: URL) async throws {
        checkouts[repository] = .found(try await checkoutResolver.locate(repository, at: directory))
    }

    private func refreshLists() async {
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

    /// Runs off the main actor, so the lists stay responsive while git is consulted.
    private func resolveCheckouts() async {
        let repositories = Set(PullRequestList.allCases.flatMap { snapshot[$0].map(\.repository) })
        do {
            let found = try await checkoutResolver.resolve(repositories)
            checkouts = repositories.reduce(into: [:]) { $0[$1] = found[$1].map(CheckoutStatus.found) ?? .notFound }
        } catch {
            FileHandle.standardError.write(Data("Couldn't look up local checkouts: \(error)\n".utf8))
        }
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

/// Whether a repo's local checkout is known.
public enum CheckoutStatus: Sendable, Equatable {
    case found(URL)
    case notFound
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}
