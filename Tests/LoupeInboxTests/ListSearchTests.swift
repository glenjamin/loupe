@testable import LoupeFakeGitHub
import Foundation
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct ListSearchTests {
    @Test func everyWordMustMatchSomewhereInThePullRequest() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try searchModel(github)
        let login = try await ownPullRequest(9101, in: github, titled: "Fix the login redirect")
        let logout = try await ownPullRequest(9102, in: github, titled: "Fix the logout button")
        await model.refresh()

        model.searchText = "LOGIN fix"
        #expect(model.pullRequests(in: .mine).map(\.id) == [login], "in any order, ignoring case")

        model.searchText = "fix   branch-9102"
        #expect(model.pullRequests(in: .mine).map(\.id) == [logout], "a title's word and a branch")

        model.searchText = "\(FakeGitHub.viewer) redirect"
        #expect(model.pullRequests(in: .mine).map(\.id) == [login], "the author and a title's word")
        #expect(model.todo().waiting.map(\.id) == [login], "waiting on rowan-ashby's review")

        model.searchText = "login button"
        #expect(model.pullRequests(in: .mine).isEmpty, "each word matches, but never in one PR")

        model.searchText = " "
        #expect(!model.isSearching)
        #expect(model.pullRequests(in: .mine).contains { $0.id == logout })
    }

    @Test func aNumberOrRepoFindsItsPullRequests() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try searchModel(github)
        let widget = try await ownPullRequest(9201, in: github, titled: "Add a widget", repository: "acme/widgets")
        let other = try await ownPullRequest(9202, in: github, titled: "Add a gadget", repository: "acme/gadgets")
        let reviewing = try await github.openPullRequest(number: 9203, by: "rowan-ashby", asking: [.user(FakeGitHub.viewer)], in: "acme/widgets").id
        await model.refresh()

        model.searchText = "#9201"
        #expect(model.pullRequests(in: .mine).map(\.id) == [widget])
        #expect(model.pullRequests(in: .toReview).isEmpty)

        model.searchText = "920"
        #expect(Set(model.pullRequests(in: .mine).map(\.id)) == [widget, other], "a bare number matches part of one")

        model.searchText = "#201"
        #expect(model.pullRequests(in: .mine).isEmpty, "# starts the number")

        model.searchText = "Widgets"
        #expect(model.pullRequests(in: .mine).map(\.id) == [widget])
        #expect(model.pullRequests(in: .toReview).map(\.id) == [reviewing])
        #expect(model.todo().review.map(\.id) == [reviewing])

        model.searchText = "acme/ rowan"
        #expect(Set(model.pullRequests(in: .mine).map(\.id)) == [widget, other], "asking rowan-ashby to review")
        #expect(model.pullRequests(in: .toReview).map(\.id) == [reviewing], "by rowan-ashby")
    }

    @Test func aSearchFindsWhatTheListsHideAsStale() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try searchModel(github)
        await model.refresh()
        let stale = try #require(model.pullRequests(in: .toReview).first)
        try await github.setRequestEvents(of: stale.id, [.init(reviewer: .user(FakeGitHub.viewer), createdAt: .now - 40 * day)])
        await model.refresh()
        #expect(!model.pullRequests(in: .toReview).contains { $0.id == stale.id })
        #expect(model.staleCount(in: .toReview) == 1)

        model.searchText = "#\(stale.number) \(stale.repository)"

        #expect(model.pullRequests(in: .toReview).map(\.id) == [stale.id], "listed, though stale")
        #expect(model.staleCount(in: .toReview) == 0, "nothing is left hidden")
        #expect(model.todo().review.isEmpty, "TODO leaves stale requests out, searching or not")
    }

    @Test func aSearchFindsTheViewersQuietPullRequestsInTheirSections() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let clock = SearchClock(at: .now)
        let model = try searchModel(github, now: { clock.now })
        let ancient = try await ownPullRequest(9301, in: github, titled: "Tidy the ancient build")
        await github.passTime(200 * day)
        clock.now += 200 * day
        let recent = try await ownPullRequest(9302, in: github, titled: "Tidy the new build", approved: true)
        await model.refresh()

        model.searchText = "tidy build"

        let todo = model.todo()
        #expect(todo.yours.map(\.id) == [recent])
        #expect(todo.overSixMonths.map(\.id) == [ancient], "in the section that starts folded")
        #expect(todo.review.isEmpty && todo.waiting.isEmpty && todo.overAMonth.isEmpty)
    }

    @Test func aMatchKeepsItsStackAndOneAboveAMismatchIsItsOwnRow() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try searchModel(github)
        let bottom = try await ownPullRequest(9401, in: github, titled: "Parser: tokens", approved: true)
        let middle = try await ownPullRequest(9402, in: github, titled: "Lexer: comments")
        let top = try await ownPullRequest(9403, in: github, titled: "Parser: errors")
        try await github.stack(middle, on: bottom)
        try await github.stack(top, on: middle)
        await model.refresh()

        model.searchText = "parser"

        let listing = model.listing(in: .mine)
        #expect(listing.map(\.pullRequest.id) == [bottom, top])
        #expect(listing.map(\.depth) == [0, 1], "stepped in over the match below it")
        #expect(listing.last?.parent?.id == middle, "still says what it's on")
        let stack = try #require(model.todo().yours.first)
        #expect(stack.id == bottom && stack.stacked.map(\.id) == [top])

        model.searchText = "lexer"

        let row = try #require(model.todo().waiting.first)
        #expect(row.id == middle && row.parent?.id == bottom, "its own row, on its parent")
    }

    @Test func nothingMatchingLeavesEveryListEmpty() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try searchModel(github)
        await model.refresh()
        #expect(!model.pullRequests(in: .mine).isEmpty && !model.pullRequests(in: .toReview).isEmpty)

        model.searchText = "no-pull-request-says-this"

        #expect(model.isSearching)
        #expect(model.pullRequests(in: .mine, includingClosed: true).isEmpty)
        #expect(model.pullRequests(in: .toReview, includingClosed: true).isEmpty)
        #expect(model.todo().isEmpty)
    }
}

/// Opens a PR by the viewer asking rowan-ashby to review it, titled `title`, with passing checks
/// and approved if asked, a minute newer than the last.
@MainActor
private func ownPullRequest(_ number: Int, in github: FakeGitHub, titled title: String, repository: String? = nil, approved: Bool = false) async throws -> String {
    await github.passTime(60)
    let id = try await github.openPullRequest(number: number, by: FakeGitHub.viewer, asking: [.user("rowan-ashby")], in: repository).id
    try await github.edit(id) { $0.title = title }
    if approved {
        try await github.review(id, by: "rowan-ashby", "APPROVED")
        try await github.edit(id) { $0.reviewDecision = "APPROVED" }
    }
    try await github.setChecks(of: id, state: "SUCCESS", [.status("ci/circleci: build", "SUCCESS")])
    try await github.setMergeState(of: id, "CLEAN", mergeable: "MERGEABLE")
    return id
}

@MainActor
private func searchModel(_ github: FakeGitHub, now: @escaping @MainActor () -> Date = { .now }) throws -> PullRequestListModel {
    try PullRequestListModel(client: github.client(), store: .inMemory(), checkoutSearchRoots: [], now: now, onOpen: { _ in })
}

private let day: TimeInterval = 24 * 60 * 60

/// A time that moves only when the test sets it.
@MainActor
private final class SearchClock {
    var now: Date

    init(at now: Date) {
        self.now = now
    }
}
