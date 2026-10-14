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
    /// Which of the PR's tabs is shown, kept while the window lives. A PR opens on its
    /// conversation, which says what it's for before its changes do.
    public var section = ReviewSection.conversation
    /// The PR's conversation: as stored when the tab opened, then as GitHub says once asked.
    public private(set) var conversation: Conversation?
    /// Why the conversation couldn't be fetched last time it was asked for.
    public private(set) var conversationError: String?
    public private(set) var isFetchingConversation = false
    /// Which commit's changes are shown, by oid, or nil for the whole PR's.
    public private(set) var shownCommit: String?
    /// Why GitHub refused the last request for a review, until another is made.
    public private(set) var reviewRequestError: String?
    /// Its markdown files as GitHub renders them, and which are shown so.
    public let markdown: MarkdownPreviews
    /// The description being edited, shown in place of the conversation, or nil when it isn't.
    public private(set) var descriptionEditor: DescriptionEditor?

    /// The PR as it was when the tab was opened, for once it has left both lists.
    private let opened: PullRequestSummary
    private let lists: PullRequestListModel
    private let store: PullRequestStore
    private let differ: PullRequestDiffer
    private let client: GitHubClient
    /// The signed-in user's login, which decides whether the PR is theirs. Read from the store,
    /// or looked up once and stored if nothing has yet.
    private var viewerLogin: String?
    /// How many changes to each path's viewed state are on their way to GitHub.
    private var settingViewed: [String: Int] = [:]
    /// The PR as it was when its diff was last asked for, success or not, or when a change to
    /// it was last dismissed. Nil until the diff is asked for.
    private var seen: PullRequestSummary?
    private var loading: Task<Void, Never>?
    /// The checkout the diff was produced from, for diffing a commit or hidden file, or reading
    /// a file to render, later.
    private(set) var checkout: URL?
    /// Each commit's changes once asked for. A range names its commits, so these never go stale.
    private var commitChanges: [DiffRange: DiffState<ReviewChanges>] = [:]
    /// Each hidden file's diff once asked for, by range and path.
    private var hiddenFileDiffs: [HiddenFileKey: DiffState<FileDiff>] = [:]

    init(opened: PullRequestSummary, lists: PullRequestListModel, store: PullRequestStore, differ: PullRequestDiffer, client: GitHubClient) {
        id = opened.id
        self.opened = opened
        self.lists = lists
        self.store = store
        self.differ = differ
        self.client = client
        markdown = MarkdownPreviews(client: client, differ: differ)
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
        readViewerLogin()
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
            async let viewer: Void = learnViewerLogin()
            await produce(pullRequest)
            await viewed
            await conversation
            await viewer
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

    /// Whether every file in the whole PR's diff is viewed as it is now. Hidden files don't
    /// count, so a reviewer isn't asked to go through vendored code.
    public var allFilesViewed: Bool {
        guard case let .ready(review) = phase, !review.changes.files.isEmpty else { return false }
        return review.changes.files.allSatisfy { viewedState(of: $0.path).isViewed }
    }

    /// The changes shown: the whole PR's, or the picked commit's once diffed. Nil until the
    /// PR's diff is ready.
    public var shownChanges: DiffState<ReviewChanges>? {
        guard case let .ready(review) = phase else { return nil }
        guard let commit = shownCommitRange(in: review) else { return .ready(review.changes) }
        return commitChanges[commit] ?? .diffing
    }

    /// Shows one commit's changes, by oid, or the whole PR's for nil, diffing the commit the
    /// first time it's picked. Keeps the shown file if the commit changed it.
    public func showCommit(_ oid: String?) async {
        guard case let .ready(review) = phase, let checkout else { return }
        shownCommit = review.commits.contains { $0.oid == oid } ? oid : nil
        guard let range = shownCommitRange(in: review) else { return keepSelection(in: review.changes) }
        switch commitChanges[range] {
        case let .ready(changes): return keepSelection(in: changes)
        case .diffing: return
        case .failed, nil: break
        }
        commitChanges[range] = .diffing
        let state: DiffState<ReviewChanges>
        do {
            let diff = try await differ.diff(range, in: checkout)
            let files = await Task.detached { DiffParser.parse(diff.text) }.value
            state = .ready(ReviewChanges(files: files, hidden: diff.hidden))
        } catch {
            state = .failed(error.localizedDescription)
        }
        commitChanges[range] = state
        if case let .ready(changes) = state, shownCommit == oid { keepSelection(in: changes) }
    }

    /// A hidden file's diff in the shown changes, once asked for.
    public func hiddenFileDiff(of path: String) -> DiffState<FileDiff>? {
        shownRange.flatMap { hiddenFileDiffs[HiddenFileKey(range: $0, path: path)] }
    }

    /// Diffs a hidden file in the shown changes on its own, unless already done or underway.
    public func diffHiddenFile(_ path: String) async {
        guard let range = shownRange, let checkout, case let .ready(changes)? = shownChanges,
              let file = changes.hidden.first(where: { $0.path == path })
        else { return }
        let key = HiddenFileKey(range: range, path: path)
        switch hiddenFileDiffs[key] {
        case .ready, .diffing: return
        case .failed, nil: break
        }
        hiddenFileDiffs[key] = .diffing
        do {
            let text = try await differ.diff(of: file, in: range, checkout: checkout)
            let parsed = await Task.detached { DiffParser.parse(text) }.value
            // A change git shows no lines for, such as of mode alone, is still the file.
            let diff = parsed.first { $0.path == path } ?? FileDiff(path: path, change: file.change, isBinary: false, hunks: [])
            hiddenFileDiffs[key] = .ready(diff)
        } catch {
            hiddenFileDiffs[key] = .failed(error.localizedDescription)
        }
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

    /// The first file after `id` in the shown changes that isn't viewed as it is now, wrapping
    /// round to the top; never `id` itself. Hidden files are passed over.
    public func nextUnviewedFile(after id: FileDiff.ID) -> FileDiff.ID? {
        guard case let .ready(changes)? = shownChanges else { return nil }
        let files = changes.files.map(\.id)
        let start = files.firstIndex(of: id).map { $0 + 1 } ?? 0
        return (files[start...] + files[..<start]).first { $0 != id && !viewedState(of: $0).isViewed }
    }

    /// The PR's reviewers and where each one's review stands, shown only on the viewer's own PRs:
    /// nil on anyone else's.
    public var reviewers: [ReviewerStatus]? {
        Conversation.reviewers(of: conversation, author: pullRequest.author, viewer: viewerLogin)
    }

    /// Who could be asked to review, matching `text`: anyone but the author and those already
    /// asked. Someone who has reviewed is included, as asking again is how a re-review is sought.
    public func reviewerCandidates(matching text: String) async throws -> [Reviewer] {
        let asked = Set(conversation?.reviewRequests.map(\.id) ?? [])
        let author = pullRequest.author
        return try await client.reviewerCandidates(in: pullRequest.repository, matching: text).filter {
            !asked.contains($0.id) && !($0.kind == .user && $0.login == author)
        }
    }

    /// Asks `reviewer` to review, or to review again. They show as asked at once; the
    /// conversation is fetched again once GitHub agrees, and they're taken off if it refuses.
    public func requestReview(from reviewer: Reviewer) async {
        if conversation?.reviewRequests.contains(where: { $0.id == reviewer.id }) == true { return }
        conversation?.reviewRequests.append(reviewer)
        reviewRequestError = nil
        do {
            try await client.requestReviews(from: [reviewer], onPullRequest: id)
        } catch {
            conversation?.reviewRequests.removeAll { $0.id == reviewer.id }
            reviewRequestError = "Couldn't ask \(reviewer.displayName) to review: \(error.localizedDescription)"
            return
        }
        await refreshConversation()
    }

    /// Whether the viewer can edit the description, which is only offered on their own PRs.
    public var canEditDescription: Bool {
        viewerLogin != nil && pullRequest.author == viewerLogin
    }

    /// Opens the description's editor with the description as it is on GitHub now, unless it's
    /// already open. Returns once that has arrived or failed.
    public func editDescription() async {
        guard canEditDescription, descriptionEditor == nil else { return }
        let editor = DescriptionEditor(pullRequestId: id, client: client)
        descriptionEditor = editor
        await editor.fetch()
    }

    /// Sends the draft to GitHub, then fetches the conversation again to show GitHub's rendering
    /// of it and closes the editor. A refused save leaves the editor open with its draft.
    public func saveDescription() async {
        guard let editor = descriptionEditor, await editor.save() else { return }
        await refreshConversation()
        if descriptionEditor === editor { descriptionEditor = nil }
    }

    /// Closes the editor, dropping any draft; asking first is the view's job.
    public func closeDescriptionEditor() {
        descriptionEditor = nil
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

    /// The lists may have stored the login since the tab opened; if not, GitHub is asked.
    private func learnViewerLogin() async {
        if viewerLogin == nil { readViewerLogin() }
        if viewerLogin != nil { return }
        do {
            let login = try await client.viewerLogin()
            viewerLogin = login
            try await store.saveViewerLogin(login)
        } catch {
            log("Couldn't look up the viewer's login: \(error.localizedDescription)")
        }
    }

    private func readViewerLogin() {
        do {
            viewerLogin = try store.viewerLogin()
        } catch {
            log("Couldn't read the viewer's login: \(error)")
        }
    }

    /// The range of the changes shown, once the PR's diff is ready.
    private var shownRange: DiffRange? {
        guard case let .ready(review) = phase else { return nil }
        return shownCommitRange(in: review) ?? DiffRange(base: review.mergeBase, head: review.headOid)
    }

    private func shownCommitRange(in review: ReviewDiff) -> DiffRange? {
        review.commits.first { $0.oid == shownCommit }?.range
    }

    /// Keeps the shown file if `changes` has it, hidden or not, else shows their first file.
    private func keepSelection(in changes: ReviewChanges) {
        if changes.files.contains(where: { $0.id == selectedFile }) || changes.hidden.contains(where: { $0.id == selectedFile }) { return }
        selectedFile = changes.files.first?.id ?? changes.hidden.first?.id
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
            let fetched = try await differ.fetch(number: pullRequest.number, of: pullRequest.repository, baseRefName: pullRequest.baseRefName, baseRefOid: pullRequest.baseRefOid, in: checkout)
            phase = .diffing
            let diff = try await differ.diff(fetched, in: checkout)
            let files = await Task.detached { DiffParser.parse(diff.text) }.value
            // Bookkeeping only; a failure to record mustn't keep the diff from showing.
            try? await store.recordDiff(DiffRecord(pullRequestId: id, headRefOid: diff.headOid, mergeBase: diff.mergeBase, producedAt: .now))
            let review = ReviewDiff(headOid: diff.headOid, mergeBase: diff.mergeBase, commits: diff.commits, changes: ReviewChanges(files: files, hidden: diff.hidden))
            self.checkout = checkout
            shownCommit = nil
            commitChanges = [:]
            hiddenFileDiffs = [:]
            keepSelection(in: review.changes)
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
    /// The PR's commits, oldest first, each of which can be shown on its own.
    public let commits: [PullRequestCommit]
    /// The whole PR's changes.
    public let changes: ReviewChanges
}

/// The changes over a range: the files to review, diffed, and those hidden as vendored,
/// lockfiles or generated, listed with what happened to each and diffed only when asked for.
public struct ReviewChanges: Sendable {
    public let files: [FileDiff]
    public let hidden: [ChangedFile]
}

/// Where a diff made on demand has got to.
public enum DiffState<Value: Sendable>: Sendable {
    case diffing
    case ready(Value)
    /// Why it failed, including git's own message.
    case failed(String)
}

private struct HiddenFileKey: Hashable {
    let range: DiffRange
    let path: String
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
