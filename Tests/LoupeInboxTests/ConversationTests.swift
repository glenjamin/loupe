@testable import LoupeFakeGitHub
import Foundation
import LoupeGit
import LoupeGitHub
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct ConversationTests {
    @Test func openingAPullRequestFetchesItsWholeTimelineAndStoresIt() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        // Enough comments to take the timeline past a page.
        for index in 1...90 { await app.conversations.comment("<p>Comment \(index)</p>", on: pullRequest.id) }
        let expected = await app.conversations.timelineCount(of: pullRequest.id)

        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        #expect(tab.conversation == nil, "nothing stored yet")
        await tab.load()

        #expect(await app.conversations.pagesServed == 2)
        let conversation = try #require(tab.conversation)
        #expect(conversation.items.count == expected)
        #expect(conversation.author?.login == "rowan-ashby")
        #expect(conversation.bodyHTML.contains("linked drill-downs"))
        #expect(conversation.body.hasPrefix("This adds linked drill-downs for reports, building on the query builder changes in #2926."), "the markdown, to edit")
        #expect(conversation.items.last?.event == .comment(bodyHTML: "<p>Comment 90</p>", isMinimized: false))
        let review = try #require(conversation.items.first { if case .review(.commented, _, _) = $0.event { true } else { false } })
        guard case let .review(_, _, comments) = review.event else { return }
        #expect(comments.count == 4)
        #expect(conversation.threads.count == 5)
        #expect(conversation.threads.filter(\.isResolved).count == 4)
        #expect(conversation.threads[0].comments.count == 4, "replies made after the review come with the thread")
        #expect(conversation.checks.map(\.status) == Array(repeating: .success, count: 6))
        #expect(conversation.checks.contains { $0.name == "ci/circleci: test" && $0.url == "https://circleci.com/gh/tamarinworks/atrium/48914" })
        #expect(conversation.checks.contains { $0.name == "codecov/patch" })
        #expect(try app.store.conversation(of: pullRequest.id) == conversation)

        // Next launch shows what was stored, before GitHub answers or if it can't.
        await app.conversations.fail()
        let nextRun = try #require(app.relaunch().tab(id: pullRequest.id))
        #expect(nextRun.conversation == conversation)
        await nextRun.load()
        #expect(nextRun.conversation == conversation)
        #expect(nextRun.conversationError != nil)
        #expect(nextRun.isConversationSettled)
    }

    @Test func aConversationThatFailedWithNoneStoredCanBeFetchedAgain() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        await app.conversations.fail()
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()
        #expect(tab.conversation == nil)
        #expect(tab.conversationError != nil)

        await app.conversations.recover()
        await tab.retryConversation()
        #expect(tab.conversation?.author?.login == "rowan-ashby")
        #expect(tab.conversationError == nil)
        #expect(tab.isConversationSettled)
    }

    @Test func reloadingFetchesTheConversationAgain() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()
        let before = try #require(tab.conversation).items.count

        await app.conversations.comment("<p>Looks good to me</p>", on: pullRequest.id, by: "reviewer")
        await tab.reload()
        let conversation = try #require(tab.conversation)
        #expect(conversation.items.count == before + 1)
        #expect(conversation.items.last?.actor?.login == "reviewer")
        #expect(try app.store.conversation(of: pullRequest.id)?.items.count == before + 1)
    }

    @Test func activityOnGitHubIsFetchedInTheBackgroundKeepingWhatsShownIfThatFails() async throws {
        let app = try await ConversationApp()
        let pullRequest = app.toReview[0]
        try await app.conversations.add(pullRequest.id)
        app.tabs.open(pullRequest)
        let tab = try #require(app.tabs.tab(id: pullRequest.id))
        await tab.load()
        let shown = try #require(tab.conversation)

        // GitHub can't be reached when the change is fetched.
        await app.conversations.comment("<p>Looks good to me</p>", on: pullRequest.id, by: "reviewer")
        try await app.github.edit(pullRequest.id) { $0.comments.totalCount += 1 }
        await app.conversations.fail()
        _ = await app.tabs.watchForChanges()
        #expect(tab.pendingChange == nil, "nothing waits on a reload")
        try await app.delay.untilWaiting()
        app.delay.elapse()
        try await until { tab.conversationError != nil }
        #expect(tab.conversation == shown)

        // The next change brings both.
        await app.conversations.recover()
        await app.conversations.comment("<p>Ship it</p>", on: pullRequest.id, by: "reviewer")
        try await app.github.edit(pullRequest.id) { $0.comments.totalCount += 1 }
        _ = await app.tabs.watchForChanges()
        try await app.delay.untilWaiting()
        app.delay.elapse()
        try await until { tab.conversationError == nil && tab.isConversationSettled }
        let conversation = try #require(tab.conversation)
        #expect(conversation.items.suffix(2).map(\.actor?.login) == ["reviewer", "reviewer"])
        #expect(conversation.items.count == shown.items.count + 2)
        #expect(try app.store.conversation(of: pullRequest.id) == conversation)
    }

    @Test func theSectionShownStartsAtTheConversationAndIsKeptPerTab() async throws {
        let app = try await ConversationApp()
        let (first, second) = (app.toReview[0], app.toReview[1])
        app.tabs.open(first)
        app.tabs.open(second)
        let firstTab = try #require(app.tabs.tab(id: first.id))
        #expect(firstTab.section == .conversation)

        firstTab.section = .files
        app.tabs.open(first)
        #expect(app.tabs.tab(id: first.id)?.section == .files)
        #expect(app.tabs.tab(id: second.id)?.section == .conversation)
    }
}

/// The app's models over the PR fixture and an in-memory store, with conversations kept by
/// `FakeConversations`.
@MainActor
struct ConversationApp {
    let github: FakeGitHub
    let details = FakePullRequestDetails()
    let store: PullRequestStore
    let tabs: TabsModel
    /// What tabs wait on before fetching changes, which only end when the test says.
    let delay = ManualDelay()
    /// What the shown PR waits on before it's checked, likewise.
    let showDelay = ManualDelay()

    /// Over `store`, or an in-memory one.
    init(store: PullRequestStore? = nil) async throws {
        github = try FakeGitHub(fixture: "pr-list.json")
        self.store = try store ?? PullRequestStore.inMemory()
        tabs = Self.tabs(github, details, self.store, delay, showDelay)
        await tabs.lists.refresh()
    }

    var conversations: FakeConversations { details.conversations }

    var toReview: [PullRequestSummary] {
        tabs.lists.pullRequests(in: .toReview)
    }

    /// The viewer's own PRs.
    var mine: [PullRequestSummary] {
        tabs.lists.pullRequests(in: .mine, includingStale: true)
    }

    /// Fresh models over the same store, as on the next launch.
    func relaunch() throws -> TabsModel {
        Self.tabs(github, details, store, delay, showDelay)
    }

    private static func tabs(_ github: FakeGitHub, _ details: FakePullRequestDetails, _ store: PullRequestStore, _ delay: ManualDelay, _ showDelay: ManualDelay) -> TabsModel {
        let lists = PullRequestListModel(client: github.client(), store: store, checkoutSearchRoots: [], onOpen: { _ in })
        return .manuallyTimed(lists: lists, store: store, client: details.client(), notifications: github.notifications(), delay: delay, showDelay: showDelay)
    }
}

/// Stands in for the time a tab waits for a burst of changes to settle: each wait lasts until
/// the test lets time pass.
@MainActor
final class ManualDelay {
    /// How long each wait asked for, in order.
    private(set) var sleeps: [Duration] = []
    private var sleepers: [CheckedContinuation<Void, Never>] = []

    func sleep(for duration: Duration) async {
        sleeps.append(duration)
        await withCheckedContinuation { sleepers.append($0) }
    }

    /// Ends every wait, as if its time had passed.
    func elapse() {
        let ended = sleepers
        sleepers = []
        for sleeper in ended { sleeper.resume() }
    }

    /// Whether something is waiting on the delay.
    var isWaiting: Bool { !sleepers.isEmpty }

    /// Waits for something to wait on the delay.
    func untilWaiting() async throws {
        try await until { !self.sleepers.isEmpty }
    }
}

extension TabsModel {
    /// Tabs whose waits last until the test elapses `delay` or `showDelay`, and whose clock stands
    /// still. Every test's tabs are made this way so that no check or fetch starts in the
    /// background unbidden, and no check falls due, in the middle of a slow-running test and
    /// changes what it sees.
    static func manuallyTimed(lists: PullRequestListModel, store: PullRequestStore, differ: PullRequestDiffer = PullRequestDiffer(), client: GitHubClient, notifications: GitHubNotifications, fallbackInterval: Duration = .seconds(60), delay: ManualDelay = ManualDelay(), showDelay: ManualDelay = ManualDelay()) -> TabsModel {
        let started = ContinuousClock.now
        return TabsModel(lists: lists, store: store, differ: differ, client: client, notifications: notifications, fallbackInterval: fallbackInterval, sleep: { await delay.sleep(for: $0) }, showDelay: { await showDelay.sleep(for: $0) }, now: { started })
    }
}

/// Waits for `condition`, for work in the background. The deadline only guards against a hang, so
/// it outlasts a whole suite run on a busy machine: every test shares the main actor, and one can
/// wait behind the rest for most of the run.
@MainActor
func until(_ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(300)
    while await !condition() {
        try #require(ContinuousClock.now < deadline, "waited too long")
        try await Task.sleep(for: .milliseconds(1))
    }
}
