import Foundation
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct TodoListTests {
    @Test func reviewListsTheLongestAskedFirstAndARePullRequestByItsFirstRequest() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try todoModel(github)
        await model.refresh()
        let toReview = model.pullRequests(in: .toReview)
        let (reRequested, older, newer) = (toReview[3], toReview[5], toReview[7])
        try await github.setRequestEvents(of: reRequested.id, [.init(reviewer: .user(FakeGitHub.viewer), createdAt: .now - days(10))])
        try await github.setRequestEvents(of: older.id, [.init(reviewer: .user(FakeGitHub.viewer), createdAt: .now - days(6))])
        try await github.setRequestEvents(of: newer.id, [.init(reviewer: .user(FakeGitHub.viewer), createdAt: .now - days(2))])
        try await github.review(reRequested.id, "APPROVED")
        await github.passTime(60)
        try await github.requestReview(of: reRequested.id)

        await model.refresh()

        let review = model.todo().review
        #expect(Array(review.map(\.id).prefix(3)) == [reRequested.id, older.id, newer.id], "first asked first, though asked again just now")
        #expect(review.first?.reason == .reRequested)
        #expect(review.dropFirst().allSatisfy { $0.reason == .reviewRequested })
        #expect(review.count == toReview.count)
    }

    @Test func anApprovedPullRequestWaitingToMergeIsLeftOutUntilItsUpdated() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try todoModel(github)
        await model.refresh()
        let approved = try #require(model.pullRequests(in: .toReview).first)
        try await github.review(approved.id, "APPROVED")
        await model.refresh()

        #expect(model.pullRequests(in: .toReview).contains { $0.id == approved.id }, "still in the lists")
        #expect(!model.todo().review.contains { $0.id == approved.id })

        await github.passTime(60)
        try await github.push(to: approved.id)
        await model.refresh()

        let updated = try #require(model.todo().review.first { $0.id == approved.id })
        #expect(updated.reason == .updatedSinceReview(.approved))
    }

    @Test func aStaleRequestStaysOutAsInTheLists() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let clock = TodoClock(at: .now)
        let model = try todoModel(github, now: { clock.now })
        await model.refresh()
        let waiting = try #require(model.pullRequests(in: .toReview).first)
        try await github.setRequestEvents(of: waiting.id, [.init(reviewer: .user(FakeGitHub.viewer), createdAt: .now - days(20))])
        await model.refresh()
        #expect(model.todo().review.first?.id == waiting.id, "asked longest ago")

        clock.now += days(11)

        #expect(!model.todo().review.contains { $0.id == waiting.id })
        #expect(model.todo().review.count == model.pullRequests(in: .toReview).count)
    }

    @Test func yoursRanksTheViewersPullRequestsByHowNearDoneTheyAre() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try todoModel(github)
        await model.refresh()
        let (ready, readyLater) = (try await ownPullRequest(9001, in: github, approved: true), try await ownPullRequest(9002, in: github, approved: true))
        let running = try await ownPullRequest(9003, in: github, approved: true, checks: "PENDING", mergeState: "BLOCKED")
        let behind = try await ownPullRequest(9004, in: github, approved: true, mergeState: "BEHIND")
        let failing = try await ownPullRequest(9005, in: github, approved: true, checks: "FAILURE", mergeState: "BLOCKED")
        let conflicts = try await ownPullRequest(9006, in: github, approved: true, mergeState: "DIRTY", mergeable: "CONFLICTING")
        let changes = try await ownPullRequest(9007, in: github, mergeState: "BLOCKED")
        try await github.review(changes, by: "rowan-ashby", "CHANGES_REQUESTED")
        try await github.edit(changes) { $0.reviewDecision = "CHANGES_REQUESTED" }
        let unasked = try await ownPullRequest(9008, in: github, asking: [], mergeState: "BLOCKED")
        let draft = try await ownPullRequest(9009, in: github, mergeState: "BLOCKED")
        try await github.edit(draft) { $0.isDraft = true }

        await model.refresh()

        let ids = [ready, readyLater, running, behind, failing, conflicts, changes, unasked, draft]
        let yours = model.todo().yours.filter { ids.contains($0.id) }
        // Newest first within a step.
        let order: [String] = [readyLater, ready, behind, running, conflicts, failing, changes, unasked, draft]
        let reasons: [TodoReason] = [
            .readyToMerge, .readyToMerge, .approvedBehind, .approvedChecksRunning, .conflicts, .checksFailing, .changesRequested, .requestReviewers, .draft,
        ]
        let labels: [String] = [
            "Ready to merge", "Ready to merge", "Approved · behind", "Approved · checks running", "Conflicts", "Checks failing", "Changes requested",
            "Request reviewers", "Draft",
        ]
        #expect(yours.map(\.id) == order)
        #expect(yours.map(\.reason) == reasons)
        #expect(yours.map(\.reason.label) == labels)
        #expect(model.todo().review.allSatisfy { !ids.contains($0.id) })
    }

    @Test func pullRequestsOnlyWaitingOnOthersAreKeptApart() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try todoModel(github)
        await model.refresh()
        let answered = try await ownPullRequest(9011, in: github, mergeState: "BLOCKED")
        try await github.review(answered, by: "rowan-ashby", "CHANGES_REQUESTED")
        try await github.edit(answered) { $0.reviewDecision = "CHANGES_REQUESTED" }
        await github.passTime(60)
        try await github.push(to: answered)
        let awaitingReview = try await ownPullRequest(9012, in: github, checks: "PENDING", mergeState: "BLOCKED")

        await model.refresh()

        let todo = model.todo()
        let waiting = todo.waiting.filter { [answered, awaitingReview].contains($0.id) }
        #expect(waiting.map(\.id) == [awaitingReview, answered], "most recently updated first")
        let reasons: [TodoReason] = [.waitingOnReview, .pushedSinceChangesRequested]
        #expect(waiting.map(\.reason) == reasons)
        #expect(!todo.yours.contains { [answered, awaitingReview].contains($0.id) })
        let mine = model.pullRequests(in: .mine).map(\.id)
        let placed: [String] = (todo.yours + todo.waiting).flatMap { item in [item.id] + item.stacked.map(\.id) }
        #expect(Set(placed) == Set(mine), "every PR of the viewer's is somewhere")
    }

    @Test func aStackOfTheViewersPullRequestsIsOneRowRankedByItsBottom() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try todoModel(github)
        await model.refresh()
        let bottom = try await ownPullRequest(9021, in: github, approved: true)
        let middle = try await ownPullRequest(9022, in: github)
        let top = try await ownPullRequest(9023, in: github)
        try await github.edit(top) { $0.isDraft = true }
        try await github.stack(middle, on: bottom)
        try await github.stack(top, on: middle)

        await model.refresh()

        let todo = model.todo()
        let stack = try #require(todo.yours.first { $0.id == bottom })
        #expect(stack.reason == .readyToMerge, "ranked by the bottom PR, whatever is above it")
        #expect(stack.stacked.map(\.id) == [middle, top])
        #expect(stack.stacked.map(\.depth) == [1, 2])
        let rows = (todo.review + todo.yours + todo.waiting).map(\.id)
        #expect(!rows.contains(middle) && !rows.contains(top), "the rest are only under their stack's row")
    }
}

/// Opens a PR by the viewer asking `reviewers` to review it, with GitHub saying its checks are
/// `checks` and it merges as `mergeState`, approved if asked, and a minute newer than the last.
@MainActor
private func ownPullRequest(
    _ number: Int,
    in github: FakeGitHub,
    asking reviewers: [FakePullRequest.Reviewer] = [.user("rowan-ashby")],
    approved: Bool = false,
    checks: String = "SUCCESS",
    mergeState: String = "CLEAN",
    mergeable: String = "MERGEABLE"
) async throws -> String {
    await github.passTime(60)
    let id = try await github.openPullRequest(number: number, by: FakeGitHub.viewer, asking: reviewers).id
    if approved {
        try await github.review(id, by: "rowan-ashby", "APPROVED")
        try await github.edit(id) { $0.reviewDecision = "APPROVED" }
    }
    try await github.setChecks(of: id, state: checks, [.status("ci/circleci: build", checks)])
    try await github.setMergeState(of: id, mergeState, mergeable: mergeable)
    return id
}

@MainActor
private func todoModel(_ github: FakeGitHub, now: @escaping @MainActor () -> Date = { .now }) throws -> PullRequestListModel {
    try PullRequestListModel(client: github.client(), store: .inMemory(), checkoutSearchRoots: [], now: now, onOpen: { _ in })
}

private func days(_ count: Double) -> TimeInterval {
    count * 24 * 60 * 60
}

/// A time that moves only when the test sets it.
@MainActor
private final class TodoClock {
    var now: Date

    init(at now: Date) {
        self.now = now
    }
}
