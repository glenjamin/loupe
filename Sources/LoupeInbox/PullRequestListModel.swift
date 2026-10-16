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

    /// Where choosing a PR goes: the app opens it in a window tab.
    public var onOpen: @MainActor (PullRequestSummary) -> Void

    private var snapshot: PullRequestSnapshot
    /// Open PRs in neither list, as last checked directly.
    private var unlisted: [String: PullRequestSummary] = [:]
    private var checkouts: [String: CheckoutStatus] = [:]
    /// How far the viewer's review of each PR whose diff has been produced has got, as stored.
    private var reviewProgress: [String: ReviewProgress] = [:]
    /// The signed-in user's login, once stored by the lists or a tab.
    private var viewer: String?
    private let client: GitHubClient
    private let checkoutResolver: CheckoutResolver
    private let store: PullRequestStore
    private let refreshInterval: Duration
    private let staleAfter: Duration
    /// Waits out the refresh interval; tests pass one they control.
    private let sleep: @Sendable (Duration) async throws -> Void
    /// The time to judge review requests' age by; tests pass one they control.
    private let now: @MainActor () -> Date

    public init(
        client: GitHubClient = GitHubClient(),
        store: PullRequestStore,
        refreshInterval: Duration = .seconds(180),
        staleAfter: Duration = .seconds(300),
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        checkoutSearchRoots: [URL] = CheckoutResolver.defaultSearchRoots,
        now: @escaping @MainActor () -> Date = { .now },
        onOpen: @escaping @MainActor (PullRequestSummary) -> Void
    ) {
        self.client = client
        self.store = store
        checkoutResolver = CheckoutResolver(store: store, searchRoots: checkoutSearchRoots)
        self.refreshInterval = refreshInterval
        self.staleAfter = staleAfter
        self.sleep = sleep
        self.now = now
        self.onOpen = onOpen
        do {
            snapshot = try store.snapshot()
        } catch {
            snapshot = PullRequestSnapshot.empty
            self.error = error.localizedDescription
        }
        do {
            reviewProgress = try store.reviewProgress()
            viewer = try store.viewerLogin()
        } catch {
            FileHandle.standardError.write(Data("Couldn't read review progress: \(error)\n".utf8))
        }
    }

    /// Whether the PR is the viewer's own and they've marked every file to review in its diff of
    /// the current head viewed, so it's ready for others to review. Known only for PRs whose diff
    /// has been produced here.
    public func isSelfReviewed(_ pullRequest: PullRequestSummary) -> Bool {
        reviewProgress[pullRequest.id]?.isSelfReviewed(pullRequest, viewer: viewer) ?? false
    }

    /// Reads the PR's review progress and the viewer's login from the store again, once a tab has
    /// stored a diff, viewed states or the login.
    func reviewProgressChanged(of id: String) {
        do {
            reviewProgress[id] = try store.reviewProgress(of: id)
            viewer = try store.viewerLogin()
        } catch {
            FileHandle.standardError.write(Data("Couldn't read review progress: \(error)\n".utf8))
        }
    }

    /// Newest first. Closed and merged PRs stay stored, but are left out unless asked for. So do
    /// PRs whose request for the viewer's review has gone unanswered too long to be worth
    /// listing; a fresh request brings one back. Asked for, those follow the rest, newest first,
    /// so the recent ones keep their place at the top.
    public func pullRequests(in list: PullRequestList, includingClosed: Bool = false, includingStaleRequests: Bool = false) -> [PullRequestSummary] {
        let listed = listed(in: list, includingClosed: includingClosed)
        let recent = listed.filter { !isStaleRequest($0, in: list) }
        guard includingStaleRequests else { return recent }
        return recent + listed.filter { isStaleRequest($0, in: list) }
    }

    /// How many PRs `pullRequests(in:includingClosed:)` leaves out for their review request's
    /// age.
    public func staleRequestCount(in list: PullRequestList, includingClosed: Bool = false) -> Int {
        listed(in: list, includingClosed: includingClosed).count { isStaleRequest($0, in: list) }
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

    /// The stored PR with `id`, whatever its state, if it's in either list or has been checked
    /// directly.
    public func pullRequest(id: String) -> PullRequestSummary? {
        for list in PullRequestList.allCases {
            if let found = snapshot[list].first(where: { $0.id == id }) { return found }
        }
        return unlisted[id]
    }

    /// The stored PR numbered `number` in `repository`, whatever its state, if it's in either
    /// list or has been checked directly. Repo names aren't case-sensitive, as on GitHub.
    public func pullRequest(repository: String, number: Int) -> PullRequestSummary? {
        let matches = { (pullRequest: PullRequestSummary) in
            pullRequest.number == number && pullRequest.repository.caseInsensitiveCompare(repository) == .orderedSame
        }
        for list in PullRequestList.allCases {
            if let found = snapshot[list].first(where: matches) { return found }
        }
        return unlisted.values.first(where: matches)
    }

    /// Looks up the PR numbered `number` in `repository` on GitHub, for one stored nowhere yet,
    /// and keeps it as checked directly. Nil when GitHub has no such PR the viewer can see.
    func lookUpPullRequest(repository: String, number: Int) async throws -> PullRequestSummary? {
        guard let found = try await client.pullRequest(repository: repository, number: number) else { return nil }
        let listed = PullRequestList.allCases.contains { list in snapshot[list].contains { $0.id == found.id } }
        if !listed { unlisted[found.id] = found }
        return found
    }

    /// Looks up the PRs with `ids` on GitHub directly, rather than waiting for the lists'
    /// refresh, and stores them, so their windows see what changed.
    public func checkForChanges(to ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        let found = try await client.pullRequests(ids: ids)
        snapshot = try await store.update(found)
        for pullRequest in found {
            let listed = PullRequestList.allCases.contains { list in snapshot[list].contains { $0.id == pullRequest.id } }
            unlisted[pullRequest.id] = listed ? nil : pullRequest
        }
    }

    /// Looks up the checks, merge state and review decision of the listed PRs with `ids` on
    /// GitHub directly, for when something done from here changes whether they can merge.
    public func checkStatuses(of ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        snapshot = try await store.updateStatuses(try await client.statuses(ofPullRequests: ids))
    }

    /// Nil until the repo's checkout has been looked for.
    public func checkout(for repository: String) -> CheckoutStatus? {
        checkouts[repository]
    }

    /// The directories searched for a repo's checkout, so a manual locate can start there.
    public var checkoutSearchRoots: [URL] {
        checkoutResolver.searchRoots
    }

    /// Brings each list up to date with GitHub, then looks up the listed PRs' statuses and finds
    /// their repos' checkouts. A list never loaded before is fetched in full; after that only PRs
    /// changed since its last refresh are fetched. A list that fails to load keeps its stored rows.
    public func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        await refreshLists()
        await refreshStatuses()
        isLoading = false
        await resolveCheckouts()
    }

    /// Looks up the checkout of `repository` now, searching for it if none is stored.
    public func resolveCheckout(for repository: String) async throws -> URL? {
        let found = try await checkoutResolver.resolve([repository])[repository]
        checkouts[repository] = found.map(CheckoutStatus.found) ?? .notFound
        return found
    }

    /// Records `directory` as the checkout of `repository`, if it's a git repo whose origin is that
    /// repo on GitHub; otherwise throws, saying why.
    public func locateCheckout(for repository: String, at directory: URL) async throws {
        checkouts[repository] = .found(try await checkoutResolver.locate(repository, at: directory))
    }

    private func refreshLists() async {
        var failures: [String] = []
        for list in PullRequestList.allCases {
            // Anything updated while the request is in flight is caught by the next one.
            let startedAt = Date.now
            do {
                // Rows stored before commit oids were fetched lack them; a full load fills them in.
                if let lastRefreshed = snapshot.refreshedAt(list), !snapshot[list].contains(where: { $0.headRefOid == nil }) {
                    let since = lastRefreshed - Self.refreshOverlap.timeInterval
                    let changed = try await client.pullRequests(in: list, updatedSince: since)
                    snapshot = try await store.merge(list, with: changed, refreshedAt: startedAt)
                } else {
                    let open = try await client.pullRequests(in: list)
                    snapshot = try await store.replace(list, with: open, refreshedAt: startedAt)
                }
                if list == .toReview { try await checkReviewRequests() }
            } catch {
                let message = error.localizedDescription
                if !failures.contains(message) { failures.append(message) }
            }
        }
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// A PR stops matching `review-requested:@me` once reviewed, so changes since the last
    /// refresh never report it leaving; each to-review PR is checked directly instead. The same
    /// check finds when each was last asked of the viewer, which search doesn't say.
    private func checkReviewRequests() async throws {
        let ids = snapshot[.toReview].map(\.id)
        guard !ids.isEmpty else { return }
        let login = try await viewerLogin()
        let requests = try await client.reviewRequests(for: ids)
        snapshot = try await store.updateReviewRequestTimes(requests.mapValues { $0.lastRequested(of: login) })
        let fulfilled = ids.filter { requests[$0]?.awaitReview(from: login) != true }
        guard !fulfilled.isEmpty else { return }
        snapshot = try await store.remove(fulfilled, from: .toReview)
    }

    private func viewerLogin() async throws -> String {
        if let login = try store.viewerLogin() {
            viewer = login
            return login
        }
        let login = try await client.viewerLogin()
        try await store.saveViewerLogin(login)
        viewer = login
        return login
    }

    /// Each open PR's checks and mergeability, looked up by id as asking the searches for them
    /// takes a full page to GitHub's time limit. Every open PR is asked about, as a check
    /// finishing doesn't change a PR's update time, so the searches for changes never report it.
    /// A failure leaves the statuses last looked up, and doesn't count as the lists failing to
    /// refresh.
    private func refreshStatuses() async {
        var ids: [String] = []
        for list in PullRequestList.allCases {
            for pullRequest in snapshot[list] where pullRequest.state == .open && !ids.contains(pullRequest.id) {
                ids.append(pullRequest.id)
            }
        }
        guard !ids.isEmpty else { return }
        do {
            snapshot = try await store.updateStatuses(try await client.statuses(ofPullRequests: ids))
        } catch {
            FileHandle.standardError.write(Data("Couldn't look up PR statuses: \(error)\n".utf8))
        }
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
            try? await sleep(refreshInterval)
        }
    }

    public func open(_ pullRequest: PullRequestSummary) {
        onOpen(pullRequest)
    }

    /// How far before the last refresh to ask for changes from, allowing for clock skew and
    /// GitHub's search index lagging behind its updates.
    static let refreshOverlap = Duration.seconds(120)

    /// How long a request for the viewer's review stays listed unanswered: long enough that only
    /// requests nobody means to act on pass it, not merely slow ones.
    static let staleRequestAge: TimeInterval = 90 * 24 * 60 * 60

    private func listed(in list: PullRequestList, includingClosed: Bool) -> [PullRequestSummary] {
        includingClosed ? snapshot[list] : snapshot[list].filter { $0.state == .open }
    }

    /// Whether `pullRequest` waits on a review request older than `staleRequestAge`. GitHub
    /// records a request as an update, so the PR's update time stands in when no request of the
    /// viewer is known.
    public func isStaleRequest(_ pullRequest: PullRequestSummary, in list: PullRequestList) -> Bool {
        guard list == .toReview else { return false }
        let requestedAt = pullRequest.reviewRequestedAt ?? pullRequest.updatedAt
        return now().timeIntervalSince(requestedAt) > Self.staleRequestAge
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
