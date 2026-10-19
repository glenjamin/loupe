import Foundation
import LoupeCore
import LoupeGit
import LoupeGitHub
import LoupeModel
import LoupeStore
import Observation

/// One open PR: its latest known details and its diff, produced from the local checkout and
/// kept in memory, so switching back to its tab is instant. When new commits are pushed while
/// it's being read the diff stays as it is, with the threads placed on it, and they're offered
/// as a reload, as github.com does; coming back to the tab takes them at once. Everything else
/// on GitHub is fetched in the background.
@Observable
@MainActor
public final class PullRequestTab: Identifiable {
    public let id: String
    public private(set) var phase = ReviewPhase.producing(.resolvingCheckout)
    /// While a ready diff is produced again, such as for new commits, how far that has got. The
    /// diff stays as it was, still the phase's, until the new one replaces it.
    public private(set) var reloading: DiffStep?
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
    public internal(set) var conversation: Conversation?
    /// Why the conversation couldn't be fetched last time it was asked for.
    public private(set) var conversationError: String?
    public private(set) var isFetchingConversation = false
    /// Why GitHub couldn't be asked whether the PR has changed, until a check gets through. The
    /// PR stays shown as stored meanwhile.
    public internal(set) var checkError: String?
    /// Whether GitHub is being asked for anything that updates the PR or its conversation: a
    /// refresh of the lists it's in, a lookup of it by id, a fetch of its conversation, or of
    /// its threads as the viewer comes to the tab.
    public var isCheckingGitHub: Bool {
        isFetchingConversation || catchingUpThreads > 0 || lists.isChecking(id)
    }
    /// Which changes are shown: the whole PR's, one commit's, or those since an earlier head.
    public private(set) var shownChoice = ChangesChoice.all
    /// The changes picked to show next, while they're diffed. The changes shown stay until
    /// they're ready, so they don't blank out for a moment.
    public private(set) var pendingChoice: ChangesChoice?

    /// Whether the changes shown are on their way out: being reloaded, or other changes picked
    /// are being diffed to replace them.
    public var isReplacingShownChanges: Bool {
        reloading != nil || pendingChoice != nil
    }
    /// Whether the list of commits to pick from is open, kept while switching between tabs.
    public var isPickingCommit = false
    /// Why GitHub refused the last request for a review, until another is made.
    public private(set) var reviewRequestError: String?
    /// Whether a merge, or taking the PR out of draft, is on its way to GitHub.
    public private(set) var isMerging = false
    /// Why GitHub refused the last merge or "Ready for review", until another is tried.
    public private(set) var mergeError: String?
    /// Its markdown files as GitHub renders them, and which are shown so.
    public let markdown: MarkdownPreviews
    /// Its image files as read from the checkout, and how each is compared.
    public let images: ImagePreviews
    /// The description being edited, shown in place of the conversation, or nil when it isn't.
    public private(set) var descriptionEditor: DescriptionEditor?
    /// The unchanged lines revealed around each file's hunks.
    public let contextExpansions: ContextExpansions
    /// What's been opened up among the review threads.
    public let threadActivity = ThreadActivity()
    /// The comment being written on the PR itself, in its conversation.
    public let conversationComment = ConversationComment()
    /// The viewer's comments and review summaries being edited.
    public let commentEdits = CommentEdits()
    /// Checking the PR's branch out to open the checkout in an editor.
    public let editorLaunch = EditorLaunch()
    /// The review threads as last fetched while the diff was of the PR's head, which stay
    /// placed on it while new commits wait for a reload.
    var threadsOfShownDiff: [ReviewThread] = []
    /// The viewer's review being finished.
    public let reviewDraft = ReviewDraft()
    /// The viewer's changes to the conversation that a fetch landing may not have yet.
    @ObservationIgnored var ownChanges: [OwnChange] = []
    @ObservationIgnored var nextOwnChange = 0
    /// How many fetches of the conversation or its threads have started, and which of them
    /// haven't landed or failed yet.
    @ObservationIgnored var fetchesStarted = 0
    @ObservationIgnored var fetchesUnderway: Set<Int> = []
    /// The viewer's pending review being started, which a second comment waits for rather than
    /// starting another, as GitHub allows one per viewer per PR.
    @ObservationIgnored var reviewStart: Task<PostedReview, any Error>?

    /// Awaited as each step of git work starts; a snapshot run holds one there to draw it.
    @ObservationIgnored public var beforeStep: @MainActor (DiffStep) async -> Void = { _ in }

    /// Opens a linked PR in its own tab; set by `TabsModel`.
    @ObservationIgnored var linkOpener: @MainActor (PullRequestLink) async -> Bool = { _ in false }

    /// The PR as it was when the tab was opened, for once it has left both lists.
    private let opened: PullRequestSummary
    let lists: PullRequestListModel
    let store: PullRequestStore
    private let differ: PullRequestDiffer
    let client: GitHubClient
    /// Who could review in each repo, shared with the other tabs.
    private let candidates: ReviewerCandidates
    /// Who GitHub suggests should review this PR, or nil until it has said.
    private var suggestedReviewers: [Reviewer]?
    /// The fetch of suggested reviewers on its way, shared by everyone asking meanwhile.
    @ObservationIgnored private var suggesting: Task<Void, Never>?
    /// The signed-in user's login, which decides whether the PR is theirs. Read from the store,
    /// or looked up once and stored if nothing has yet.
    public private(set) var viewerLogin: String?
    /// How many changes to each path's viewed state are on their way to GitHub.
    private var settingViewed: [String: Int] = [:]
    /// The PR as it was when its diff was last asked for, success or not, or when its new
    /// commits were last dismissed. Nil until the diff is asked for.
    private var seen: PullRequestSummary?
    /// The check underway as the viewer comes to the tab, while which new commits are about to
    /// be reloaded rather than offered.
    private var catchingUp: Task<Void, Never>?
    /// How many fetches of the threads made as the viewer comes to the tab are underway.
    private var catchingUpThreads = 0
    private var loading: Task<Void, Never>?
    /// The PR as it was when its conversation and viewed states were last asked for, to tell
    /// when GitHub has more. Nil until they're first asked for.
    private var followed: PullRequestSummary?
    /// Waiting for a burst of changes to settle, then fetching them.
    private var following: Task<Void, Never>?
    /// Waits out the settling delay; tests pass one they control.
    private let sleep: @Sendable (Duration) async throws -> Void
    /// The checkout the diff was produced from, for diffing a commit or hidden file, or reading
    /// a file to render, later.
    private(set) var checkout: URL?
    /// The changes of each commit, or since an anchor, once asked for. A range names its commits,
    /// so these never go stale.
    private var pickedChanges: [DiffRange: DiffState<ReviewChanges>] = [:]
    /// Each commit's diff-stat, or the changes' since an anchor, once counted, which like their
    /// changes never go stale.
    private var rangeStats: [DiffRange: DiffStat] = [:]
    private var countingCommits: Task<Void, Never>?
    /// The head of the PR's diff shown the last time it was opened before this tab, read as the
    /// tab is made, so it stays put while the tab is open whatever's shown meanwhile.
    private let lastOpened: SeenHead?
    /// Whether the changes since each anchor can be shown, by the range they'd be.
    private var anchorStates: [DiffRange: AnchorState] = [:]
    private var preparingAnchors: Task<Void, Never>?
    /// Each hidden file's diff once asked for, by range and path.
    private var hiddenFileDiffs: [HiddenFileKey: DiffState<FileDiff>] = [:]
    /// Each hidden file's latest diff, of whichever range, to show while another is made.
    private var lastHiddenFileDiffs: [String: FileDiff] = [:]
    /// Each hidden npm lockfile's package changes once asked for, by range and path.
    private var packageLockChanges: [HiddenFileKey: DiffState<PackageLockChanges>] = [:]
    /// The npm lockfiles shown as their diff rather than their package changes.
    private var rawPackageLocks: Set<String> = []

    init(opened: PullRequestSummary, lists: PullRequestListModel, store: PullRequestStore, differ: PullRequestDiffer, client: GitHubClient, candidates: ReviewerCandidates, sleep: @escaping @Sendable (Duration) async throws -> Void) {
        id = opened.id
        self.sleep = sleep
        self.opened = opened
        self.lists = lists
        self.store = store
        self.differ = differ
        self.client = client
        self.candidates = candidates
        markdown = MarkdownPreviews(client: client, differ: differ)
        images = ImagePreviews(differ: differ)
        contextExpansions = ContextExpansions(differ: differ)
        do {
            lastOpened = try store.seenHead(of: id)
        } catch {
            lastOpened = nil
            log("Couldn't read when \(opened.repository)#\(opened.number) was last opened: \(error)")
        }
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
        threadsOfShownDiff = conversation?.threads ?? []
        readViewerLogin()
        watchStoredPullRequest()
    }

    /// As of the lists' last refresh.
    public var pullRequest: PullRequestSummary {
        lists.pullRequest(id: id) ?? opened
    }

    /// Opens the PR a link in this one names, in its own tab. False when it can't, so the link
    /// can go to the browser instead.
    public func open(_ link: PullRequestLink) async -> Bool {
        await linkOpener(link)
    }

    /// `repo #number`.
    public var title: String {
        let pullRequest = pullRequest
        let name = pullRequest.repository.split(separator: "/").last.map(String.init) ?? pullRequest.repository
        return "\(name) #\(pullRequest.number)"
    }

    /// How the PR has changed on GitHub since its diff was produced, if in a way that waits for
    /// the viewer to reload the diff: nil while the diff is still of the PR's head, or while
    /// it's about to be reloaded without asking.
    public var pendingChange: PendingChange? {
        guard hasNewCommits, catchingUp == nil else { return nil }
        return .newCommits
    }

    /// The review threads the diff places on its rows: the conversation's, except while new
    /// commits wait for a reload or are being reloaded, when they're as they were for the diff
    /// shown, as GitHub places threads by the head's lines and the new head's could land on the
    /// wrong rows.
    public var placedThreads: [ReviewThread] {
        holdsPlacedThreads ? threadsOfShownDiff : conversation?.threads ?? []
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
        followed = pullRequest
        let task = Task {
            async let viewed: Void = refreshViewedStates()
            async let conversation: Void = refreshConversation()
            async let viewer: Void = learnViewerLogin()
            await produce(pullRequest)
            await viewed
            await conversation
            await viewer
            loading = nil
            followStoredChanges()
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
            checkError = nil
        } catch {
            // The stored PR is diffed instead; it's what prompted the reload.
            checkError = error.localizedDescription
            log("Couldn't check \(title) for changes: \(error)")
        }
        await retry()
    }

    /// Checks the PR with `check` as the viewer comes to the tab, then reloads the diff if it
    /// has new commits rather than offering them, as none of them is being read yet; any already
    /// waiting stop being offered at once. A comment being written on a line keeps them offered
    /// instead, as the new head could move its line. Without a reload the threads and pending
    /// review are fetched, as a review started or ended on github.com shows no activity. Joins a
    /// catch-up already underway.
    @discardableResult
    func catchUp(checking check: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        if let catchingUp { return catchingUp }
        guard !isWritingOnLine else {
            return Task {
                await check()
                await catchUpThreads()
            }
        }
        let task = Task {
            await check()
            catchingUp = nil
            if hasNewCommits { await retry() } else { await catchUpThreads() }
        }
        catchingUp = task
        return task
    }

    /// Whether new commits wait for a reload that coming back to the tab can make at once.
    var reloadsOnReturn: Bool {
        hasNewCommits && !isWritingOnLine
    }

    /// Keeps the diff as it is and stops offering the new commits, until more are pushed. Its
    /// threads then follow GitHub again.
    public func dismissPendingChange() {
        if seen != nil { seen = pullRequest }
        followPlacedThreads()
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

    /// Whether the PR is the viewer's own and every file to review in its diff of the current
    /// head is viewed, so it's ready for others to review. Follows the viewer's marks as they're
    /// made; until the diff is ready, it's as stored.
    public var isSelfReviewed: Bool {
        guard case let .ready(review) = phase else { return lists.isSelfReviewed(pullRequest) }
        let progress = ReviewProgress(diffedHeadRefOid: review.headOid, reviewablePaths: review.changes.files.map(\.path), viewedStates: viewedStates)
        return progress.isSelfReviewed(pullRequest, viewer: viewerLogin)
    }

    /// The changes shown: the whole PR's, one commit's, or those since an anchor. Nil until the
    /// PR's diff is ready.
    public var shownChanges: DiffState<ReviewChanges>? {
        guard case let .ready(review) = phase else { return nil }
        guard shownChoice != .all, let range = range(of: shownChoice, in: review) else { return .ready(review.changes) }
        return pickedChanges[range] ?? .diffing
    }

    /// Shows the changes `choice` names, diffing them the first time they're picked; until then
    /// they're pending and the changes shown stay. Keeps the shown file if they change it. The
    /// changes since an anchor can be picked only once it's known they can be shown.
    public func show(_ choice: ChangesChoice) async {
        guard case let .ready(review) = phase, let checkout else { return }
        if case let .since(anchor) = choice, anchorState(of: anchor) != .ready { return }
        guard choice != .all, let range = range(of: choice, in: review) else {
            pendingChoice = nil
            shownChoice = .all
            return keepSelection(in: review.changes)
        }
        switch pickedChanges[range] {
        case let .ready(changes):
            pendingChoice = nil
            shownChoice = choice
            return keepSelection(in: changes)
        case .diffing:
            pendingChoice = choice
            return
        case .failed, nil:
            pendingChoice = choice
        }
        pickedChanges[range] = .diffing
        await beforeStep(.diffing)
        let state: DiffState<ReviewChanges>
        do {
            let diff = try await differ.diff(range, in: checkout)
            let files = await Task.detached { DiffParser.parse(diff.text) }.value
            state = .ready(ReviewChanges(files: files, hidden: diff.hidden))
        } catch {
            state = .failed(error.localizedDescription)
        }
        pickedChanges[range] = state
        // Unless another choice, or a reload, has come since.
        guard pendingChoice == choice else { return }
        pendingChoice = nil
        shownChoice = choice
        if case let .ready(changes) = state { keepSelection(in: changes) }
    }

    /// How much `choice` changes the files to review: the whole PR's from its diff, a commit's
    /// or the changes since an anchor once counted. Hidden files aren't counted, as in the
    /// count of files reviewed.
    public func diffStat(of choice: ChangesChoice) -> DiffStat? {
        guard case let .ready(review) = phase else { return nil }
        guard choice != .all else { return DiffStat(review.changes.files) }
        return range(of: choice, in: review).flatMap { rangeStats[$0] }
    }

    /// Counts each commit's changes with git, unless already counted. A failure leaves them
    /// uncounted, to be tried again when next asked.
    public func countCommitChanges() async {
        if let countingCommits {
            await countingCommits.value
            return await countCommitChanges()
        }
        guard case let .ready(review) = phase, let checkout else { return }
        let ranges = review.commits.map(\.range).filter { rangeStats[$0] == nil }
        guard !ranges.isEmpty else { return }
        let task = Task {
            do {
                rangeStats.merge(try await differ.stats(of: ranges, in: checkout)) { $1 }
            } catch {
                log("Couldn't count the changes of \(title)'s commits: \(error.localizedDescription)")
            }
            countingCommits = nil
        }
        countingCommits = task
        await task.value
    }

    /// The earlier heads of the PR the viewer saw that the changes since can be picked from: the
    /// one their latest submitted review was made against, then the one shown when the PR was
    /// last opened before this tab. Each only once known and if the head has moved on from it.
    public var anchors: [ChangesAnchor] {
        guard case let .ready(review) = phase else { return [] }
        let lastReview = conversation?.viewerReview.map { ChangesAnchor(kind: .lastReview, oid: $0.commitOid, at: $0.submittedAt) }
        let lastOpened = lastOpened.map { ChangesAnchor(kind: .lastOpened, oid: $0.headRefOid, at: $0.seenAt) }
        return [lastReview, lastOpened].compactMap { $0 }.filter { $0.oid != review.headOid }
    }

    /// Whether the changes since `anchor` can be shown, once it's been looked at.
    public func anchorState(of anchor: ChangesAnchor) -> AnchorState? {
        guard case let .ready(review) = phase else { return nil }
        return anchorStates[DiffRange(base: anchor.oid, head: review.headOid)]
    }

    /// Looks at each anchor not yet looked at, or that failed, bringing its commit into the
    /// checkout from the remote if it isn't there: if the head has only gained commits since, its
    /// changes since are counted and can be shown; if the PR was rebased since, they can't yet.
    public func prepareAnchors() async {
        if let preparingAnchors {
            await preparingAnchors.value
            return await prepareAnchors()
        }
        guard case let .ready(review) = phase, let checkout else { return }
        let ranges = anchors.map { DiffRange(base: $0.oid, head: review.headOid) }.filter { range in
            switch anchorStates[range] {
            case nil, .failed: true
            case .checking, .ready, .rebased: false
            }
        }
        guard !ranges.isEmpty else { return }
        let repository = pullRequest.repository
        let task = Task {
            for range in ranges { anchorStates[range] = .checking }
            for range in ranges {
                do {
                    switch try await differ.ancestry(of: range.base, toHead: range.head, of: repository, in: checkout) {
                    case .ancestor:
                        rangeStats.merge(try await differ.stats(of: [range], in: checkout)) { $1 }
                        anchorStates[range] = .ready
                    case .rebased:
                        anchorStates[range] = .rebased
                    }
                } catch {
                    anchorStates[range] = .failed(error.localizedDescription)
                }
            }
            preparingAnchors = nil
        }
        preparingAnchors = task
        await task.value
    }

    /// A hidden file's diff in the shown changes, once asked for.
    public func hiddenFileDiff(of path: String) -> DiffState<FileDiff>? {
        shownRange.flatMap { hiddenFileDiffs[HiddenFileKey(range: $0, path: path)] }
    }

    /// The hidden file's diff last made, of any range, to stand in while the shown changes' is
    /// made. Nil if it hasn't been diffed.
    public func lastHiddenFileDiff(of path: String) -> FileDiff? {
        lastHiddenFileDiffs[path]
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
        await beforeStep(.diffing)
        do {
            let text = try await differ.diff(of: file, in: range, checkout: checkout)
            let parsed = await Task.detached { DiffParser.parse(text) }.value
            // A change git shows no lines for, such as of mode alone, is still the file.
            let diff = parsed.first { $0.path == path } ?? FileDiff(path: path, change: file.change, isBinary: false, hunks: [])
            hiddenFileDiffs[key] = .ready(diff)
            lastHiddenFileDiffs[path] = diff
        } catch {
            hiddenFileDiffs[key] = .failed(error.localizedDescription)
        }
    }

    /// A hidden npm lockfile's package changes in the shown changes, once asked for.
    public func packageLockChanges(of path: String) -> DiffState<PackageLockChanges>? {
        shownRange.flatMap { packageLockChanges[HiddenFileKey(range: $0, path: path)] }
    }

    /// Compares a hidden npm lockfile's packages at the shown changes' base and head, unless
    /// done or underway. A lockfile can be megabytes, so it's parsed off the main actor. A
    /// failure, including a lockfile that won't parse, is kept to say why.
    public func comparePackageLock(_ path: String) async {
        guard PackageLockChanges.isPackageLock(path), let range = shownRange, let checkout, case let .ready(changes)? = shownChanges,
              let file = changes.hidden.first(where: { $0.path == path })
        else { return }
        let key = HiddenFileKey(range: range, path: path)
        switch packageLockChanges[key] {
        case .ready, .diffing: return
        case .failed, nil: break
        }
        packageLockChanges[key] = .diffing
        let differ = differ
        do {
            // An added file has no base to compare with, and a deleted one no head.
            async let base: String? = file.change == .added ? nil : differ.contents(of: file.renamedFrom ?? path, at: range.base, in: checkout)
            async let head: String? = file.change == .deleted ? nil : differ.contents(of: path, at: range.head, in: checkout)
            let (before, after) = try await (base, head)
            let compared = try await Task.detached { try PackageLockChanges.compare(base: before, head: after) }.value
            packageLockChanges[key] = .ready(compared)
        } catch {
            packageLockChanges[key] = .failed(error.localizedDescription)
        }
    }

    /// Whether a hidden npm lockfile shows its diff rather than its package changes, kept per
    /// path while the tab lives.
    public func showsRawDiff(of path: String) -> Bool {
        rawPackageLocks.contains(path)
    }

    public func setShowsRawDiff(_ raw: Bool, path: String) {
        if raw {
            rawPackageLocks.insert(path)
        } else {
            rawPackageLocks.remove(path)
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
        lists.reviewProgressChanged(of: id)
    }

    public func toggleViewed(path: String) async {
        await setViewed(!viewedState(of: path).isViewed, path: path)
    }

    /// Marks the shown file viewed and shows the next one not viewed, after it in the list or
    /// else from the top. With none left in a single commit, shows the next commit, on its
    /// first file not viewed; otherwise the file stays shown.
    public func markViewedAndAdvance() async {
        guard let current = selectedFile else { return }
        if let next = nextUnviewedFile(after: current) {
            selectedFile = next
        } else if let commit = nextCommit {
            async let marking: Void = setViewed(true, path: current)
            await show(.commit(commit.oid))
            if shownChoice == .commit(commit.oid), case let .ready(changes)? = shownChanges {
                // The file just marked counts as viewed, whether or not GitHub has answered yet.
                let files = FileTree(paths: changes.files.map(\.path)).files
                selectedFile = files.first { $0 != current && !viewedState(of: $0).isViewed } ?? files.first ?? selectedFile
            }
            return await marking
        }
        await setViewed(true, path: current)
    }

    /// The commit after the one shown, in the picker's order, where moving on goes once the shown
    /// commit's files are all viewed. Nil while the whole PR's changes, those since an earlier
    /// head, or the last commit's are shown.
    public var nextCommit: PullRequestCommit? {
        guard case let .ready(review) = phase, case let .commit(oid) = shownChoice,
              let index = review.commits.firstIndex(where: { $0.oid == oid })
        else { return nil }
        return review.commits.indices.contains(index + 1) ? review.commits[index + 1] : nil
    }

    /// The first file after `id` in the shown changes, in the file list's tree order, that isn't
    /// viewed as it is now, wrapping round to the top; never `id` itself. Hidden files are
    /// passed over.
    public func nextUnviewedFile(after id: FileDiff.ID) -> FileDiff.ID? {
        guard case let .ready(changes)? = shownChanges else { return nil }
        let files = FileTree(paths: changes.files.map(\.path)).files
        let start = files.firstIndex(of: id).map { $0 + 1 } ?? 0
        return (files[start...] + files[..<start]).first { $0 != id && !viewedState(of: $0).isViewed }
    }

    /// The PR's reviewers and where each one's review stands, shown only on the viewer's own PRs:
    /// nil on anyone else's.
    public var reviewers: [ReviewerStatus]? {
        Conversation.reviewers(of: conversation, author: pullRequest.author, viewer: viewerLogin)
    }

    /// Fetches who could be asked to review in the PR's repo, unless they have been this run,
    /// and who GitHub suggests for this PR, unless it has said. Suggestions that can't be
    /// fetched are logged and left out rather than holding back the rest.
    public func fetchReviewerCandidates() async throws {
        async let suggesting: Void = fetchSuggestedReviewers()
        do {
            try await candidates.fetch(pullRequest.repository, store: store)
        } catch {
            await suggesting
            throw error
        }
        await suggesting
    }

    /// Who could be asked to review, of those fetched, whose login or name contains `text`: anyone
    /// but the author and those already asked. Someone who has reviewed is included, as asking
    /// again is how a re-review is sought. GitHub's suggestions for the PR come first, then those
    /// asked lately in the repo. Nil until they've been fetched.
    public func reviewerCandidates(matching text: String) -> [Reviewer]? {
        let asked = Set(conversation?.reviewRequests.map(\.id) ?? [])
        let author = pullRequest.author
        return candidates.candidates(in: pullRequest.repository, suggested: suggestedReviewers ?? [])?.filter {
            !asked.contains($0.id) && !($0.kind == .user && $0.login == author)
                && (text.isEmpty || $0.login.localizedCaseInsensitiveContains(text) || $0.name?.localizedCaseInsensitiveContains(text) == true)
        }
    }

    /// Whether GitHub suggests `reviewer` for this PR.
    public func isSuggestedReviewer(_ reviewer: Reviewer) -> Bool {
        suggestedReviewers?.contains { $0.id == reviewer.id } == true
    }

    /// Asks `reviewer` to review, or to review again. They show as asked at once; the
    /// conversation is fetched again once GitHub agrees, and they're taken off if it refuses.
    /// An accepted request is kept in the history that orders the candidates, and the PR's row
    /// in the lists names them at once.
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
        await candidates.recordRequest(of: reviewer, in: pullRequest.repository, on: id, store: store)
        do {
            try await lists.reviewRequested(of: RequestedReviewer(reviewer), on: id)
        } catch {
            log("Couldn't store the request of \(reviewer.login) on \(title): \(error)")
        }
        await refreshConversation()
    }

    /// Whether the PR can be merged from here, offered only on the viewer's own PRs: nil on
    /// anyone else's, and once it's merged or closed.
    public var mergeReadiness: MergeReadiness? {
        guard isViewersOwn else { return nil }
        return MergeReadiness(pullRequest)
    }

    /// Merges the PR with a merge commit, provided its head is still the one last looked up,
    /// then looks it up again so it shows as merged everywhere. A refusal is kept to show.
    public func merge() async {
        let pullRequest = pullRequest
        guard !isMerging, mergeReadiness == .ready, let head = pullRequest.headRefOid else { return }
        isMerging = true
        defer { isMerging = false }
        mergeError = nil
        do {
            try await client.mergePullRequest(id: id, expectedHeadOid: head)
        } catch {
            mergeError = "Couldn't merge: \(error.localizedDescription)"
            return
        }
        do {
            try await lists.checkForChanges(to: [id])
        } catch {
            log("Couldn't look up \(title) after merging it: \(error.localizedDescription)")
        }
    }

    /// Takes the draft out of draft on GitHub, then looks it up again, merge state included, so
    /// the header, its tab and the merge box show it ready for review. A refusal is kept to show.
    public func markReadyForReview() async {
        guard !isMerging, mergeReadiness == .draft else { return }
        isMerging = true
        defer { isMerging = false }
        mergeError = nil
        do {
            try await client.markReadyForReview(id: id)
        } catch {
            mergeError = "Couldn't mark ready for review: \(error.localizedDescription)"
            return
        }
        do {
            try await lists.checkForChanges(to: [id])
            try await lists.checkStatuses(of: [id])
        } catch {
            log("Couldn't look up \(title) after marking it ready for review: \(error.localizedDescription)")
        }
    }

    /// The signed-in user's login, once known.
    public var viewer: String? { viewerLogin }

    /// Whether the viewer can edit the description, which is only offered on their own PRs.
    public var canEditDescription: Bool {
        isViewersOwn
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

    /// Fetches the conversation again after it failed, leaving the diff as it is.
    public func retryConversation() async {
        guard !isFetchingConversation else { return }
        await refreshConversation()
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
        lists.reviewProgressChanged(of: id)
    }

    /// Takes the conversation from GitHub and stores it, keeping what was shown if it fails.
    func refreshConversation() async {
        isFetchingConversation = true
        defer { isFetchingConversation = false }
        let started = startFetch()
        defer { endFetch(started) }
        var fetched: Conversation
        do {
            fetched = try await client.conversation(ofPullRequest: id)
        } catch {
            conversationError = error.localizedDescription
            log("Couldn't get the conversation of \(title): \(error.localizedDescription)")
            return
        }
        remakeOwnChanges(over: &fetched, fetchedFrom: started)
        conversation = fetched
        conversationError = nil
        followPlacedThreads()
        do {
            try await store.replaceConversation(of: id, with: fetched, fetchedAt: .now)
        } catch {
            log("Couldn't store the conversation of \(title): \(error)")
        }
    }

    /// Follows each new copy of the PR the lists store, for as long as the tab lives.
    private func watchStoredPullRequest() {
        withObservationTracking {
            _ = pullRequest
        } onChange: { [weak self] in
            // Called as the change is about to be made, so it's read once made.
            Task { @MainActor in
                self?.watchStoredPullRequest()
                self?.followStoredChanges()
            }
        }
    }

    /// Fetches the conversation, its review threads with it, and the viewed states again once
    /// the stored PR shows activity on GitHub since they were last asked for, new commits
    /// included. Waits for a burst of changes to settle first, and never overlaps a fetch
    /// underway.
    private func followStoredChanges() {
        guard following == nil, loading == nil, hasUnfollowedActivity else { return }
        let sleep = sleep
        following = Task { [weak self] in
            try? await sleep(PullRequestTab.followDelay)
            await self?.followActivity()
        }
    }

    private func followActivity() async {
        if loading == nil, hasUnfollowedActivity {
            followed = pullRequest
            async let viewed: Void = refreshViewedStates()
            async let conversation: Void = refreshConversation()
            await viewed
            await conversation
        }
        following = nil
        // Anything stored while this was fetching.
        followStoredChanges()
    }

    /// Whether the stored PR has activity not yet fetched.
    private var hasUnfollowedActivity: Bool {
        guard let followed else { return false }
        return !pullRequest.hasSameActivity(as: followed)
    }

    /// How long a change waits for others before it's fetched.
    static let followDelay = Duration.seconds(2)

    /// Places the conversation's threads on the diff as they are now, unless new commits wait
    /// for a reload or are being reloaded.
    func followPlacedThreads() {
        if !holdsPlacedThreads { threadsOfShownDiff = conversation?.threads ?? [] }
    }

    /// Whether the threads stay as placed for the diff shown, which is of an older head.
    var holdsPlacedThreads: Bool {
        hasNewCommits || reloading != nil
    }

    /// Whether the PR's head has moved since its diff was produced.
    private var hasNewCommits: Bool {
        guard let seen else { return false }
        return pullRequest.headRefOid != seen.headRefOid
    }

    /// Whether a comment with something typed, or on its way, is open on a line of the diff,
    /// which a reload could put on a different line.
    private var isWritingOnLine: Bool {
        let isSendingOnLine = ownChanges.contains { change in
            if case .comment(_, _, startsThread: true, _) = change.kind { change.answeredBefore == nil } else { false }
        }
        return isSendingOnLine || threadActivity.newComment?.draft.hasText == true
    }

    /// Fetches the threads and the viewer's pending review, placing the viewer's pending threads
    /// on the diff, unless a fetch of the whole conversation, which brings them too, is underway
    /// or about to start.
    private func catchUpThreads() async {
        guard loading == nil, !isFetchingConversation, !hasUnfollowedActivity else { return }
        catchingUpThreads += 1
        defer { catchingUpThreads -= 1 }
        await refreshThreads { $0.isPending }
    }

    /// The lists may have stored the login since the tab opened; if not, GitHub is asked.
    private func learnViewerLogin() async {
        if viewerLogin == nil { readViewerLogin() }
        if viewerLogin != nil { return }
        do {
            let login = try await client.viewerLogin()
            viewerLogin = login
            try await store.saveViewerLogin(login)
            lists.reviewProgressChanged(of: id)
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

    private var isViewersOwn: Bool {
        viewerLogin != nil && pullRequest.author == viewerLogin
    }

    /// Fetches GitHub's suggested reviewers once a tab, sharing a fetch already on its way. A
    /// failure is logged and tried again next time.
    private func fetchSuggestedReviewers() async {
        if suggestedReviewers != nil { return }
        if let suggesting { return await suggesting.value }
        let client = client
        let pullRequest = pullRequest
        let task = Task {
            do {
                suggestedReviewers = try await client.suggestedReviewers(pullRequestId: pullRequest.id)
            } catch {
                log("Couldn't fetch the suggested reviewers of \(pullRequest.repository)#\(pullRequest.number): \(error)")
            }
        }
        suggesting = task
        await task.value
        suggesting = nil
    }

    /// The range of the changes shown, once the PR's diff is ready.
    var shownRange: DiffRange? {
        guard case let .ready(review) = phase else { return nil }
        return range(of: shownChoice, in: review) ?? DiffRange(base: review.mergeBase, head: review.headOid)
    }

    /// What `choice` diffs, or nil for a commit that isn't the PR's.
    private func range(of choice: ChangesChoice, in review: ReviewDiff) -> DiffRange? {
        switch choice {
        case .all: DiffRange(base: review.mergeBase, head: review.headOid)
        case let .commit(oid): review.commits.first { $0.oid == oid }?.range
        case let .since(anchor): DiffRange(base: anchor.oid, head: review.headOid)
        }
    }

    /// Keeps the shown file if `changes` has it, hidden or not, else shows the first file the
    /// list shows.
    private func keepSelection(in changes: ReviewChanges) {
        if changes.files.contains(where: { $0.id == selectedFile }) || changes.hidden.contains(where: { $0.id == selectedFile }) { return }
        selectedFile = FileTree(paths: changes.files.map(\.path)).files.first ?? FileTree(paths: changes.hidden.map(\.path)).files.first
    }

    /// Produces the diff of `pullRequest`. A diff already shown stays, its phase still ready,
    /// while the new one is made, so a reload doesn't blank it; a failure replaces it.
    private func produce(_ pullRequest: PullRequestSummary) async {
        let replacesShownDiff = if case .ready = phase { true } else { false }
        func start(_ step: DiffStep) async {
            if replacesShownDiff { reloading = step } else { phase = .producing(step) }
            await beforeStep(step)
        }
        defer { reloading = nil }
        do {
            await start(.resolvingCheckout)
            guard let checkout = try await lists.resolveCheckout(for: pullRequest.repository) else {
                phase = .noCheckout
                // Looked for afresh when the tab is next shown, in case it has turned up.
                seen = nil
                return
            }
            await start(.fetching)
            let fetched = try await differ.fetch(number: pullRequest.number, of: pullRequest.repository, baseRefName: pullRequest.baseRefName, baseRefOid: pullRequest.baseRefOid, in: checkout)
            await start(.diffing)
            let diff = try await differ.diff(fetched, in: checkout)
            let files = await Task.detached { DiffParser.parse(diff.text) }.value
            // Bookkeeping only; a failure to record mustn't keep the diff from showing.
            let record = DiffRecord(pullRequestId: id, headRefOid: diff.headOid, mergeBase: diff.mergeBase, producedAt: .now, reviewablePaths: files.map(\.path))
            try? await store.recordDiff(record)
            // For the next tab to open on the PR; this one's anchor stays as it was read.
            try? await store.recordSeenHead(diff.headOid, of: id, at: .now)
            lists.reviewProgressChanged(of: id)
            let review = ReviewDiff(headOid: diff.headOid, mergeBase: diff.mergeBase, commits: diff.commits, changes: ReviewChanges(files: files, hidden: diff.hidden))
            self.checkout = checkout
            shownChoice = .all
            pendingChoice = nil
            pickedChanges = [:]
            rangeStats = [:]
            anchorStates = [:]
            hiddenFileDiffs = [:]
            packageLockChanges = [:]
            contextExpansions.reset()
            keepSelection(in: review.changes)
            reloading = nil
            followPlacedThreads()
            phase = .ready(review)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }
}

/// How an open PR has changed on GitHub since its diff was produced, in a way that waits for
/// the reviewer to reload.
public enum PendingChange: Sendable, Equatable {
    /// Its head commit moved, so the diff is out of date.
    case newCommits
}

/// The PR view's two tabs, as on github.com.
public enum ReviewSection: Sendable, Hashable {
    case conversation
    case files
}

/// Where a tab's diff has got to.
public enum ReviewPhase: Sendable {
    /// Being produced for the first time, or after a failure.
    case producing(DiffStep)
    /// No local checkout of the repo is known, so there's nothing to diff.
    case noCheckout
    case ready(ReviewDiff)
    /// Why it failed, including git's own message.
    case failed(String)
}

/// The steps of producing a PR's diff, in order. Diffing is also the one step of diffing a
/// commit or a hidden file on demand.
public enum DiffStep: Sendable, Equatable {
    case resolvingCheckout
    /// Fetching the PR's head, and its base, from origin.
    case fetching
    case diffing
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

/// Which changes the files show, as the commit picker picks them.
public enum ChangesChoice: Hashable, Sendable {
    /// The whole PR's, from where it branched off.
    case all
    /// One commit's, by oid.
    case commit(String)
    /// The PR's head's since an earlier head the viewer saw.
    case since(ChangesAnchor)
}

/// An earlier head of the PR the viewer saw, which the changes since can be shown from.
public struct ChangesAnchor: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The head the viewer's latest submitted review was made against.
        case lastReview
        /// The head shown the last time the viewer opened the PR, before the tab open now.
        case lastOpened
    }

    public let kind: Kind
    public let oid: String
    /// When the viewer reviewed or opened it, if known.
    public let at: Date?

    public init(kind: Kind, oid: String, at: Date?) {
        self.kind = kind
        self.oid = oid
        self.at = at
    }
}

/// Whether the changes since an anchor can be shown.
public enum AnchorState: Sendable, Equatable {
    /// Its commit is being brought in, or looked at.
    case checking
    /// The head has only gained commits since, and the changes are counted.
    case ready
    /// The PR was rebased or force-pushed since, so its changes since would be swamped by its
    /// base's; a view across a rebase isn't built yet.
    case rebased
    /// Why its commit couldn't be fetched or looked at, including git's own message.
    case failed(String)
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
    /// Whether nothing shown from the conversation could have changed since `earlier`. Counts
    /// unknown either side aren't compared.
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
