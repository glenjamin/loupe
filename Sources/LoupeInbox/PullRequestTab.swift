import Foundation
import LoupeCore
import LoupeGit
import LoupeModel
import LoupeStore
import Observation

/// One PR's tab: its latest known details and its diff, produced from the local checkout and
/// kept in memory, so switching back to the tab is instant. The diff is produced again when the
/// PR's head commit changes.
@Observable
@MainActor
public final class PullRequestTab: Identifiable {
    public let id: String
    public private(set) var phase = ReviewPhase.resolvingCheckout
    /// The file shown, kept while switching between tabs.
    public var selectedFile: FileDiff.ID?

    /// The PR as it was when the tab was opened, for once it has left both lists.
    private let opened: PullRequestSummary
    private let lists: PullRequestListModel
    private let store: PullRequestStore
    private let differ: PullRequestDiffer
    /// The head commit the PR had when its diff was last asked for, success or not.
    private var attemptedHead: String??
    private var loading: Task<Void, Never>?

    init(opened: PullRequestSummary, lists: PullRequestListModel, store: PullRequestStore, differ: PullRequestDiffer) {
        id = opened.id
        self.opened = opened
        self.lists = lists
        self.store = store
        self.differ = differ
    }

    /// As of the lists' last refresh.
    public var pullRequest: PullRequestSummary {
        lists.pullRequest(id: id) ?? opened
    }

    /// `repo #number`.
    public var title: String {
        let pullRequest = pullRequest
        let name = pullRequest.repository.split(separator: "/").last.map(String.init) ?? pullRequest.repository
        return "\(name) #\(pullRequest.number)"
    }

    /// Produces the diff, unless it has already been tried for the PR's current head commit.
    /// Returns once it's ready or has failed.
    public func load() async {
        if let loading {
            await loading.value
            return await load()
        }
        let pullRequest = pullRequest
        if attemptedHead == .some(pullRequest.headRefOid) { return }
        attemptedHead = .some(pullRequest.headRefOid)
        let task = Task {
            await produce(pullRequest)
            loading = nil
        }
        loading = task
        await task.value
    }

    /// Produces the diff again, after a failure.
    public func retry() async {
        attemptedHead = nil
        await load()
    }

    /// Records `directory` as the repo's checkout, if its origin is the repo, then produces the
    /// diff from it.
    public func locateCheckout(at directory: URL) async throws {
        try await lists.locateCheckout(for: pullRequest.repository, at: directory)
        await retry()
    }

    private func produce(_ pullRequest: PullRequestSummary) async {
        phase = .resolvingCheckout
        do {
            guard let checkout = try await lists.resolveCheckout(for: pullRequest.repository) else {
                phase = .noCheckout
                // Looked for afresh when the tab is next shown, in case it has turned up.
                attemptedHead = nil
                return
            }
            phase = .fetching
            let fetched = try await differ.fetch(number: pullRequest.number, baseRefName: pullRequest.baseRefName, baseRefOid: pullRequest.baseRefOid, in: checkout)
            phase = .diffing
            let diff = try await differ.diff(fetched, in: checkout)
            let parts = await Task.detached { PathFilter.default.partition(DiffParser.parse(diff.text)) }.value
            // Bookkeeping only; a failure to record mustn't keep the diff from showing.
            try? await store.recordDiff(DiffRecord(pullRequestId: id, headRefOid: diff.headOid, mergeBase: diff.mergeBase, producedAt: .now))
            let review = ReviewDiff(headOid: diff.headOid, mergeBase: diff.mergeBase, files: parts.included, hiddenCount: diff.hiddenPaths.count + parts.excluded.count)
            if !review.files.contains(where: { $0.id == selectedFile }) {
                selectedFile = review.files.first?.id
            }
            phase = .ready(review)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// Where a tab's diff has got to.
public enum ReviewPhase: Sendable {
    case resolvingCheckout
    /// No local checkout of the repo is known, so there's nothing to diff.
    case noCheckout
    case fetching
    case diffing
    case ready(ReviewDiff)
    /// Why it failed, including git's own message.
    case failed(String)
}

public struct ReviewDiff: Sendable {
    public let headOid: String
    public let mergeBase: String
    /// The files to review.
    public let files: [FileDiff]
    /// How many changed files were left out as vendored, lockfiles or generated.
    public let hiddenCount: Int
}
