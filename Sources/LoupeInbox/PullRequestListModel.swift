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
    /// How many lookups by id of each PR are on their way to GitHub; they can overlap.
    private var lookingUp: [String: Int] = [:]
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

    /// Newest first, those waiting on the viewer's review before those they've approved or asked
    /// changes of, so what needs them leads. Closed and merged PRs stay stored, but are left out
    /// unless asked for. So are stale ones, too old to be worth listing; a fresh request, or
    /// activity on a PR the viewer gave a verdict on, brings one back. Asked for, those come
    /// last, newest first, so the rest keep their place. The PRs of one stack are listed
    /// together, from the bottom up, where the first of them would be.
    public func pullRequests(in list: PullRequestList, includingClosed: Bool = false, includingStale: Bool = false) -> [PullRequestSummary] {
        listing(in: list, includingClosed: includingClosed, includingStale: includingStale).map(\.pullRequest)
    }

    /// `pullRequests(in:includingClosed:includingStale:)` with each one's place in its stack.
    public func listing(in list: PullRequestList, includingClosed: Bool = false, includingStale: Bool = false) -> [StackedPullRequest] {
        stacks.grouped(ordered(in: list, includingClosed: includingClosed, includingStale: includingStale))
    }

    /// How the open PRs known here stack, listed or not.
    public var stacks: PullRequestStacks {
        PullRequestStacks(PullRequestList.allCases.flatMap { snapshot[$0] } + Array(unlisted.values) + snapshot.unlisted)
    }

    private func ordered(in list: PullRequestList, includingClosed: Bool, includingStale: Bool) -> [PullRequestSummary] {
        let listed = listed(in: list, includingClosed: includingClosed)
        let recent = listed.filter { !isStale($0, in: list) }
        let awaiting = recent.filter { verdict(on: $0, in: list) == nil }
        let reviewed = recent.filter { verdict(on: $0, in: list) != nil }
        guard includingStale else { return awaiting + reviewed }
        return awaiting + reviewed + listed.filter { isStale($0, in: list) }
    }

    /// The viewer's approval or request for changes on a PR in `list` that's there for it
    /// rather than for a request of their review, so its row can say it waits to be merged or
    /// on its author. Nil anywhere but To review.
    public func verdict(on pullRequest: PullRequestSummary, in list: PullRequestList) -> ReviewState? {
        guard list == .toReview, let viewer else { return nil }
        return pullRequest.standingVerdict(of: viewer)
    }

    /// How many PRs `pullRequests(in:includingClosed:)` leaves out as stale.
    public func staleCount(in list: PullRequestList, includingClosed: Bool = false) -> Int {
        listed(in: list, includingClosed: includingClosed).count { isStale($0, in: list) }
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
        return unlisted[id] ?? snapshot.unlisted.first { $0.id == id }
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
        return unlisted.values.first(where: matches) ?? snapshot.unlisted.first(where: matches)
    }

    /// Whether GitHub is being asked for anything that updates the stored PR with `id`: a
    /// refresh of the lists it's in, or a lookup of it by id.
    public func isChecking(_ id: String) -> Bool {
        lookingUp[id] != nil || (isLoading && PullRequestList.allCases.contains { list in snapshot[list].contains { $0.id == id } })
    }

    /// Looks up the PR numbered `number` in `repository` on GitHub, for one stored nowhere yet.
    /// It joins the lists it belongs in at once, rather than at their next refresh; otherwise
    /// it's kept as checked directly. Nil when GitHub has no such PR the viewer can see.
    func lookUpPullRequest(repository: String, number: Int) async throws -> PullRequestSummary? {
        guard let found = try await client.pullRequest(repository: repository, number: number) else { return nil }
        try await placeInLists([found])
        return pullRequest(id: found.pullRequest.id) ?? found.pullRequest
    }

    /// Looks up the PRs with `ids` on GitHub directly, rather than waiting for the lists'
    /// refresh, and stores them, so their windows see what changed. One newly asking for the
    /// viewer's review joins To review at once.
    public func checkForChanges(to ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await checking(ids) {
            let found = try await client.pullRequests(ids: ids)
            snapshot = try await store.update(found.map(\.pullRequest))
            try await placeInLists(found)
        }
    }

    /// Looks up the checks, merge state and review decision of the listed PRs with `ids` on
    /// GitHub directly, for when something done from here changes whether they can merge.
    public func checkStatuses(of ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await checking(ids) {
            snapshot = try await store.updateStatuses(try await client.statuses(ofPullRequests: ids))
        }
    }

    /// Adds `reviewer` to those the PR with `id` waits on, once GitHub has accepted asking them
    /// from here, so its row says so before the next refresh.
    func reviewRequested(of reviewer: RequestedReviewer, on id: String) async throws {
        guard var pullRequest = pullRequest(id: id) else { return }
        var requested = pullRequest.requestedReviewers ?? []
        guard !requested.contains(reviewer) else { return }
        requested.append(reviewer)
        snapshot = try await store.updateRequestedReviewers([id: requested])
        if unlisted[id] != nil {
            pullRequest.requestedReviewers = requested
            unlisted[id] = pullRequest
        }
    }

    /// Records the viewer's approval or request for changes on the PR with `id`, once GitHub has
    /// accepted it from here, so its row says so before the next refresh. It answers their
    /// request for review, as on GitHub.
    func viewerGave(_ verdict: ReviewVerdict, on id: String) async throws {
        guard verdict.state.isVerdict else { return }
        if let requested = pullRequest(id: id)?.requestedReviewers, requested.contains(where: { $0.isUser(verdict.login) }) {
            snapshot = try await store.updateRequestedReviewers([id: requested.filter { !$0.isUser(verdict.login) }])
        }
        snapshot = try await store.updateViewerReviews([id: verdict])
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
        await lookUpStacks(around: PullRequestList.allCases.flatMap { snapshot[$0] }, refreshing: snapshot.unlisted)
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
                var refreshed: PullRequestSnapshot
                if let lastRefreshed = snapshot.refreshedAt(list), !snapshot[list].contains(where: { $0.headRefOid == nil }) {
                    let since = lastRefreshed - Self.refreshOverlap.timeInterval
                    let changed = try await client.pullRequests(in: list, updatedSince: since)
                    refreshed = try await store.merge(list, with: changed, refreshedAt: startedAt)
                } else {
                    let open = try await client.pullRequests(in: list)
                    refreshed = try await store.replace(list, with: open, refreshedAt: startedAt)
                }
                // Shown only once checked, so a PR the viewer has only commented on, which the
                // search of their reviews finds, doesn't flash up before the check drops it.
                if list == .toReview { refreshed = try await checkReviewRequests(in: refreshed) }
                snapshot = refreshed
            } catch {
                if let stored = try? store.snapshot() { snapshot = stored }
                let message = error.localizedDescription
                if !failures.contains(message) { failures.append(message) }
            }
        }
        error = failures.isEmpty ? nil : failures.joined(separator: "\n")
    }

    /// A PR stops matching `review-requested:@me` once reviewed, and `reviewed-by:@me is:open`
    /// once merged, so changes since the last refresh never report it leaving; each to-review
    /// PR in `refreshed` is checked directly instead. It stays while open and either waiting on
    /// the viewer or holding their approval or request for changes. The same check finds when
    /// each was last asked of the viewer, which search doesn't say. The viewer's own open PRs
    /// are checked alongside, for who each waits on, as asking search for that takes a full
    /// page past GitHub's time limit.
    private func checkReviewRequests(in refreshed: PullRequestSnapshot) async throws -> PullRequestSnapshot {
        let ids = refreshed[.toReview].map(\.id)
        let mine = refreshed[.mine].filter { $0.state == .open && !ids.contains($0.id) }.map(\.id)
        guard !ids.isEmpty || !mine.isEmpty else { return refreshed }
        let login = try await viewerLogin()
        let requests = try await client.reviewRequests(for: ids + mine)
        var checked = try await store.updateRequestedReviewers(requests.mapValues(\.reviewers))
        guard !ids.isEmpty else { return checked }
        let toReview = requests.filter { ids.contains($0.key) }
        checked = try await store.updateReviewRequestTimes(toReview.mapValues { $0.lastRequested(of: login) })
        checked = try await store.updateViewerReviews(toReview.mapValues { $0.latestVerdictReview(by: login) })
        let leaving = ids.filter { requests[$0]?.belongsInToReview(of: login) != true }
        guard !leaving.isEmpty else { return checked }
        return try await store.remove(leaving, from: .toReview)
    }

    /// Adds each looked-up PR to the lists it belongs in but isn't yet, as the searches would
    /// once they see it, and records when the viewer was last asked to review those in To
    /// review, and their verdict on them. The rest are kept as checked directly. Nothing is taken out of a list here; the
    /// refresh's own checks do that.
    private func placeInLists(_ lookups: [PullRequestLookup]) async throws {
        let login = try await viewerLogin()
        for lookup in lookups {
            let id = lookup.pullRequest.id
            let joining = Self.lists(for: lookup, viewer: login).filter { list in !snapshot[list].contains { $0.id == id } }
            guard !joining.isEmpty else { continue }
            snapshot = try await store.add(lookup.pullRequest, to: joining, at: now())
        }
        let requested = lookups.filter { lookup in snapshot[.toReview].contains { $0.id == lookup.pullRequest.id } }
        if !requested.isEmpty {
            let times = Dictionary(requested.map { ($0.pullRequest.id, $0.reviewRequests.lastRequested(of: login)) }) { $1 }
            snapshot = try await store.updateReviewRequestTimes(times)
            let verdicts = Dictionary(requested.map { ($0.pullRequest.id, $0.reviewRequests.latestVerdictReview(by: login)) }) { $1 }
            snapshot = try await store.updateViewerReviews(verdicts)
        }
        for lookup in lookups {
            let id = lookup.pullRequest.id
            let listed = PullRequestList.allCases.contains { list in snapshot[list].contains { $0.id == id } }
            unlisted[id] = listed ? nil : lookup.pullRequest
        }
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

    /// Looks up the PRs stacked with any of `pullRequests` that are open and stacked, so each
    /// stack is whole and its members current whichever lists they're in, then those stacked
    /// with the PRs found, until no more turn up. A GitHub stack is asked about once, through any
    /// one member, as that finds them all. Each of `others`, the stored PRs in neither list, is
    /// looked up too, stacked or not, so a neighbour merged since drops out. A failure leaves
    /// the stacks as last looked up, and doesn't count as the lists failing to refresh.
    func lookUpStacks(around pullRequests: [PullRequestSummary], refreshing others: [PullRequestSummary] = []) async {
        var asked: Set<String> = []
        var askedStacks: Set<String> = []
        var candidates = pullRequests
        var refreshing = others.filter { $0.state == .open }
        do {
            for _ in 0..<Self.stackLookupRounds {
                var ids = refreshing.map(\.id)
                asked.formUnion(ids)
                askedStacks.formUnion(refreshing.compactMap(\.stackId))
                for pullRequest in candidates where pullRequest.state == .open && !asked.contains(pullRequest.id) {
                    if let stackId = pullRequest.stackId {
                        guard askedStacks.insert(stackId).inserted else { continue }
                    } else if pullRequest.stackParentId == nil {
                        continue
                    }
                    asked.insert(pullRequest.id)
                    ids.append(pullRequest.id)
                }
                refreshing = []
                guard !ids.isEmpty else { return }
                let found = try await client.stackNeighbours(of: ids)
                snapshot = try await store.storeStackNeighbours(found)
                candidates = found
            }
        } catch {
            FileHandle.standardError.write(Data("Couldn't look up stacked PRs: \(error)\n".utf8))
        }
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

    /// How many PRs deep a stack is followed down its branches in one refresh; a GitHub stack is
    /// found whole at once.
    static let stackLookupRounds = 5

    /// How long a request for the viewer's review stays listed unanswered, or a PR they gave a
    /// verdict on stays listed without activity, before it's hidden as stale; the list's caption
    /// shows the hidden ones again in a click, so it can be tight.
    static let staleAge: TimeInterval = 30 * 24 * 60 * 60

    /// Counts the PRs with `ids` as being looked up on GitHub while `body` runs.
    private func checking(_ ids: [String], during body: () async throws -> Void) async rethrows {
        for id in ids { lookingUp[id, default: 0] += 1 }
        defer { for id in ids { lookingUp[id] = lookingUp[id].flatMap { $0 > 1 ? $0 - 1 : nil } } }
        try await body()
    }

    private func listed(in list: PullRequestList, includingClosed: Bool) -> [PullRequestSummary] {
        includingClosed ? snapshot[list] : snapshot[list].filter { $0.state == .open }
    }

    /// The lists the PR belongs in by what their searches match on: open and by the viewer for
    /// Mine; open and waiting on the viewer's review (or any team's), or holding their approval
    /// or request for changes, for To review.
    private static func lists(for lookup: PullRequestLookup, viewer login: String) -> [PullRequestList] {
        let pullRequest = lookup.pullRequest
        let isMine = pullRequest.state == .open && pullRequest.author?.caseInsensitiveCompare(login) == .orderedSame
        return [isMine ? .mine : nil, lookup.reviewRequests.belongsInToReview(of: login) ? .toReview : nil].compactMap(\.self)
    }

    /// Whether `pullRequest` has sat in To review longer than `staleAge`: since the viewer was
    /// asked to review it or, once they've given a verdict and it waits on its author or a merge,
    /// since its last activity. GitHub records a request or review as an update, so the PR's
    /// update time also stands in when no request of the viewer is known.
    public func isStale(_ pullRequest: PullRequestSummary, in list: PullRequestList) -> Bool {
        guard list == .toReview else { return false }
        let requestedAt = verdict(on: pullRequest, in: list) == nil ? pullRequest.reviewRequestedAt : nil
        return now().timeIntervalSince(requestedAt ?? pullRequest.updatedAt) > Self.staleAge
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
