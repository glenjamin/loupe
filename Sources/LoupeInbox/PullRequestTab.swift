import Foundation
import LoupeCore
import LoupeGit
import LoupeGitHub
import LoupeModel
import LoupeStore
import Observation

/// One open PR: its latest known details and its diff, produced from the local checkout and
/// kept in memory, so switching back to its tab is instant. When the PR changes on GitHub the
/// diff stays as it is and the change is offered as a reload, as github.com does.
@Observable
@MainActor
public final class PullRequestTab: Identifiable {
    public let id: String
    public private(set) var phase = ReviewPhase.resolvingCheckout
    /// The file shown, kept while switching between tabs.
    public var selectedFile: FileDiff.ID?
    /// The viewer's viewed state of each file, by path: as stored when the tab opened, then as
    /// GitHub says once asked, with the viewer's own changes shown before GitHub confirms them.
    public private(set) var viewedStates: [String: FileViewedState] = [:]
    /// Why the last change to a file's viewed state didn't reach GitHub, until one does.
    public private(set) var viewedStateError: String?
    /// Which of the PR's tabs is shown, kept while the window lives.
    public var section = ReviewSection.files
    /// The PR's conversation: as stored when the tab opened, then as GitHub says once asked.
    public private(set) var conversation: Conversation?
    /// Why the conversation couldn't be fetched last time it was asked for.
    public private(set) var conversationError: String?
    public private(set) var isFetchingConversation = false

    /// The PR as it was when the tab was opened, for once it has left both lists.
    private let opened: PullRequestSummary
    private let lists: PullRequestListModel
    private let store: PullRequestStore
    private let differ: PullRequestDiffer
    private let client: GitHubClient
    /// How many changes to each path's viewed state are on their way to GitHub.
    private var settingViewed: [String: Int] = [:]
    /// The PR as it was when its diff was last asked for, success or not, or when a change to
    /// it was last dismissed. Nil until the diff is asked for.
    private var seen: PullRequestSummary?
    private var loading: Task<Void, Never>?

    init(opened: PullRequestSummary, lists: PullRequestListModel, store: PullRequestStore, differ: PullRequestDiffer, client: GitHubClient) {
        id = opened.id
        self.opened = opened
        self.lists = lists
        self.store = store
        self.differ = differ
        self.client = client
        do {
            viewedStates = try store.viewedStates(of: id)
        } catch {
            log("Couldn't read the viewed files of \(opened.repository)#\(opened.number): \(error)")
        }
        do {
            conversation = try store.conversation(of: id)
        } catch {
            log("Couldn't read the conversation of \(opened.repository)#\(opened.number): \(error)")
        }
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

    /// How the PR has changed on GitHub since its diff was produced, if it has: nil while the
    /// diff is still of the PR as it is now.
    public var pendingChange: PendingChange? {
        guard let seen else { return nil }
        let now = pullRequest
        if now.headRefOid != seen.headRefOid { return .newCommits }
        return now.hasSameActivity(as: seen) ? nil : .updated
    }

    /// Produces the diff and asks GitHub which files are viewed and for the conversation, unless
    /// already asked. Returns once all three are done, one way or another.
    public func load() async {
        if let loading {
            await loading.value
            return await load()
        }
        if seen != nil { return }
        let pullRequest = pullRequest
        seen = pullRequest
        let task = Task {
            async let viewed: Void = refreshViewedStates()
            async let conversation: Void = refreshConversation()
            await produce(pullRequest)
            await viewed
            await conversation
            loading = nil
        }
        loading = task
        await task.value
    }

    /// Produces the diff again, of the PR as it's stored now, such as after a failure.
    public func retry() async {
        seen = nil
        await load()
    }

    /// Brings the PR up to date with GitHub and produces its diff and fetches its conversation
    /// again, keeping the shown file if it's still there.
    public func reload() async {
        do {
            try await lists.checkForChanges(to: [id])
        } catch {
            // The stored PR is diffed instead; it's what prompted the reload.
            log("Couldn't check \(title) for changes: \(error)")
        }
        await retry()
    }

    /// Keeps the diff as it is and stops offering the change, until the PR changes again.
    public func dismissPendingChange() {
        if seen != nil { seen = pullRequest }
    }

    /// Records `directory` as the repo's checkout, if its origin is the repo, then produces the
    /// diff from it.
    public func locateCheckout(at directory: URL) async throws {
        try await lists.locateCheckout(for: pullRequest.repository, at: directory)
        await retry()
    }

    /// Not viewed unless GitHub or the viewer has said so.
    public func viewedState(of path: String) -> FileViewedState {
        viewedStates[path] ?? .unviewed
    }

    /// Whether every file in the diff is viewed as it is now.
    public var allFilesViewed: Bool {
        guard case let .ready(review) = phase, !review.files.isEmpty else { return false }
        return review.files.allSatisfy { viewedState(of: $0.path).isViewed }
    }

    /// Marks the file viewed or not on GitHub. The change shows at once, and is put back if
    /// GitHub refuses it.
    public func setViewed(_ viewed: Bool, path: String) async {
        let previous = viewedState(of: path)
        let wanted: FileViewedState = viewed ? .viewed : .unviewed
        guard previous != wanted else { return }
        viewedStates[path] = wanted
        settingViewed[path, default: 0] += 1
        defer { settingViewed[path] = settingViewed[path].flatMap { $0 > 1 ? $0 - 1 : nil } }
        do {
            try await client.setFileViewed(viewed, path: path, pullRequestId: id)
            viewedStateError = nil
        } catch {
            // Unless changed again since, in which case that change decides.
            if viewedStates[path] == wanted { viewedStates[path] = previous }
            viewedStateError = "Couldn't mark \(path) as \(viewed ? "viewed" : "not viewed"): \(error.localizedDescription)"
            return
        }
        do {
            try await store.saveViewedState(wanted, of: path, in: id)
        } catch {
            log("Couldn't store the viewed state of \(path): \(error)")
        }
    }

    public func toggleViewed(path: String) async {
        await setViewed(!viewedState(of: path).isViewed, path: path)
    }

    /// Marks the shown file viewed and shows the next one not viewed, after it in the list or
    /// else from the top. With none left, the file stays shown.
    public func markViewedAndAdvance() async {
        guard let current = selectedFile else { return }
        if let next = nextUnviewedFile(after: current) {
            selectedFile = next
        }
        await setViewed(true, path: current)
    }

    /// The first file after `id` in the list that isn't viewed as it is now, wrapping round to
    /// the top; never `id` itself.
    public func nextUnviewedFile(after id: FileDiff.ID) -> FileDiff.ID? {
        guard case let .ready(review) = phase else { return nil }
        let files = review.files.map(\.id)
        let start = files.firstIndex(of: id).map { $0 + 1 } ?? 0
        return (files[start...] + files[..<start]).first { $0 != id && !viewedState(of: $0).isViewed }
    }

    /// Whether the conversation has been asked for and has arrived or failed.
    public var isConversationSettled: Bool {
        !isFetchingConversation && (conversation != nil || conversationError != nil)
    }

    /// Takes the viewed states from GitHub, keeping any change of the viewer's still on its way.
    private func refreshViewedStates() async {
        let fetched: [String: FileViewedState]
        do {
            fetched = try await client.viewedStates(ofPullRequest: id)
        } catch {
            log("Couldn't get the viewed files of \(title): \(error.localizedDescription)")
            return
        }
        var states = fetched
        for path in settingViewed.keys {
            states[path] = viewedStates[path]
        }
        viewedStates = states
        do {
            try await store.replaceViewedStates(of: id, with: states)
        } catch {
            log("Couldn't store the viewed files of \(title): \(error)")
        }
    }

    /// Takes the conversation from GitHub and stores it, keeping what was shown if it fails.
    private func refreshConversation() async {
        isFetchingConversation = true
        defer { isFetchingConversation = false }
        let fetched: Conversation
        do {
            fetched = try await client.conversation(ofPullRequest: id)
        } catch {
            conversationError = error.localizedDescription
            log("Couldn't get the conversation of \(title): \(error.localizedDescription)")
            return
        }
        conversation = fetched
        conversationError = nil
        do {
            try await store.replaceConversation(of: id, with: fetched, fetchedAt: .now)
        } catch {
            log("Couldn't store the conversation of \(title): \(error)")
        }
    }

    private func produce(_ pullRequest: PullRequestSummary) async {
        phase = .resolvingCheckout
        do {
            guard let checkout = try await lists.resolveCheckout(for: pullRequest.repository) else {
                phase = .noCheckout
                // Looked for afresh when the tab is next shown, in case it has turned up.
                seen = nil
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

/// How an open PR has changed on GitHub since its diff was produced.
public enum PendingChange: Sendable, Equatable {
    /// Its head commit moved, so the diff is out of date.
    case newCommits
    /// Anything else, such as a comment, a review or a change of state.
    case updated
}

/// The PR view's two tabs, as on github.com.
public enum ReviewSection: Sendable, Hashable {
    case conversation
    case files
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

private extension PullRequestSummary {
    /// Whether nothing a reviewer would reload for has changed since `earlier`. Counts unknown
    /// either side aren't compared.
    func hasSameActivity(as earlier: PullRequestSummary) -> Bool {
        func same(_ count: KeyPath<PullRequestSummary, Int?>) -> Bool {
            earlier[keyPath: count] == nil || self[keyPath: count] == nil || earlier[keyPath: count] == self[keyPath: count]
        }
        return updatedAt == earlier.updatedAt && state == earlier.state && reviewDecision == earlier.reviewDecision
            && same(\.commitCount) && same(\.commentCount) && same(\.reviewThreadCount)
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
