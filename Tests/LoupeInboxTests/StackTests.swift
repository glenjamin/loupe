import Foundation
import LoupeGitHub
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct StackTests {
    @Test func aGitHubStackShowsInTheHeaderBottomFirstWithMembersFromNeitherList() async throws {
        let app = try await ConversationApp()
        try await app.github.addCapturedStack()
        // Someone else's PR on top, which asks nothing of the viewer, so it's in neither list.
        let top = try await app.github.openPullRequest(number: 281, by: "rowan-ashby", in: "tamarinworks/gazette")
        try await app.github.stack(top.id, on: "PR_kwDOAYVX-88AAAABI5AxRA")
        await app.tabs.lists.refresh()

        let middle = try #require(app.mine.first { $0.number == 278 && $0.repository == "tamarinworks/gazette" })
        #expect(app.toReview.contains { $0.id == top.id } == false)
        app.tabs.open(middle)
        let tab = try #require(app.tabs.tab(id: middle.id))
        let line = try #require(tab.stackLine)
        #expect(line.levels.map { $0.map(\.number) } == [[277], [278], [281]])
        #expect(line.current == middle.id)

        // The stack outlasts a relaunch, as what's stacked with a listed PR is stored.
        let nextRun = try #require(app.relaunch().tab(id: middle.id))
        #expect(nextRun.stackLine?.levels.map { $0.map(\.number) } == [[277], [278], [281]])

        // Clicking a member opens its tab, whether or not it's listed.
        await tab.open(PullRequestLink(repository: "tamarinworks/gazette", number: 281))
        #expect(app.tabs.tab(id: top.id) != nil)
        #expect(app.tabs.selected == top.id)
        #expect(app.tabs.tab(id: top.id)?.stackLine?.current == top.id)
    }

    @Test func aStackByBranchesAloneIsFollowedDownThroughPullRequestsInNeitherList() async throws {
        let app = try await ConversationApp()
        let bottom = try await app.github.openPullRequest(number: 900, by: "rowan-ashby")
        let middle = try await app.github.openPullRequest(number: 901, by: "mara-kettle")
        let mine = try await app.github.openPullRequest(number: 902, by: FakeGitHub.viewer)
        try await app.github.stack(middle.id, on: bottom.id, linked: false)
        try await app.github.stack(mine.id, on: middle.id, linked: false)
        await app.tabs.lists.refresh()

        app.tabs.open(try #require(app.mine.first { $0.id == mine.id }))
        let line = try #require(app.tabs.tab(id: mine.id)?.stackLine)
        #expect(line.levels.map { $0.map(\.number) } == [[900], [901], [902]])
        // Neither of the two below is in a list, so the row says what it's on.
        let listed = try #require(app.tabs.lists.listing(in: .mine).first { $0.id == mine.id })
        #expect(listed.parent?.number == 901)
        #expect(listed.depth == 0)
    }

    @Test func aPullRequestWithTwoOnItShowsThemSideBySideAndEndsTheLine() async throws {
        let app = try await ConversationApp()
        let base = try await app.github.openPullRequest(number: 910, by: FakeGitHub.viewer)
        let left = try await app.github.openPullRequest(number: 911, by: FakeGitHub.viewer)
        let right = try await app.github.openPullRequest(number: 912, by: FakeGitHub.viewer)
        let onLeft = try await app.github.openPullRequest(number: 913, by: FakeGitHub.viewer)
        try await app.github.stack(left.id, on: base.id, linked: false)
        try await app.github.stack(right.id, on: base.id, linked: false)
        try await app.github.stack(onLeft.id, on: left.id, linked: false)
        await app.tabs.lists.refresh()

        let stacks = app.tabs.lists.stacks
        let mine = app.mine
        let listedBase = try #require(mine.first { $0.id == base.id })
        let listedLeft = try #require(mine.first { $0.id == left.id })
        let line = try #require(stacks.line(through: listedBase))
        #expect(line.levels.map { $0.map(\.number) } == [[910], [911, 912]])
        let fromLeft = try #require(stacks.line(through: listedLeft))
        #expect(fromLeft.levels.map { $0.map(\.number) } == [[910], [911], [913]])

        // Listed as a tree: each branch of the fork after the PR it's on, the deeper one further in.
        let group = app.tabs.lists.listing(in: .mine).filter { (910...913).contains($0.pullRequest.number) }
        #expect(group.map(\.pullRequest.number) == [910, 911, 913, 912])
        #expect(group.map(\.depth) == [0, 1, 2, 1])
    }

    @Test func aStackIsListedTogetherBottomFirstWhereItsNewestMemberGoes() async throws {
        let app = try await ConversationApp()
        try await app.github.addCapturedStack()
        await app.tabs.lists.refresh()
        let mine = app.tabs.lists.listing(in: .mine)
        let numbers = mine.map { "\($0.pullRequest.repository.split(separator: "/")[1]) #\($0.pullRequest.number)" }

        // The newest of the stack, #278, leads the list, but the bottom comes first.
        #expect(Array(numbers.prefix(2)) == ["gazette #277", "gazette #278"])
        #expect(mine.prefix(2).map(\.depth) == [0, 1])
        #expect(mine[1].parent?.number == 277)

        // The fixture's stacks by branch alone are grouped the same way.
        let draft = try #require(numbers.firstIndex(of: "gazette #273"))
        #expect(numbers[draft - 1] == "gazette #272")
        #expect(mine[draft].depth == 1)
        let sidebar = try #require(numbers.firstIndex(of: "stagehand #1727"))
        #expect(numbers[sidebar - 1] == "stagehand #1726")

        // Activity on the bottom moves the whole group, still bottom first.
        try await app.github.edit("PR_kwDOAYVX-88AAAABI4ybXQ") { $0.title = "Stop publishing to legacy board channels, for good" }
        await app.github.passTime(60)
        try await app.github.edit(try #require(app.mine.first { $0.number == 272 && $0.repository == "tamarinworks/gazette" }).id) { $0.title = "Skip panel cache writes" }
        await app.tabs.lists.refresh()
        #expect(app.mine.prefix(4).map(\.number) == [272, 273, 277, 278])
    }

    @Test func toReviewGroupsTheStackedPullRequestsItHolds() async throws {
        let app = try await ConversationApp()
        let bottom = try await app.github.openPullRequest(number: 920, by: "rowan-ashby", asking: [.user(FakeGitHub.viewer)])
        let top = try await app.github.openPullRequest(number: 921, by: "rowan-ashby", asking: [.user(FakeGitHub.viewer)])
        try await app.github.stack(top.id, on: bottom.id)
        // Something else newer than either, to come between them if they weren't grouped.
        _ = try await app.github.openPullRequest(number: 922, by: "mara-kettle", asking: [.user(FakeGitHub.viewer)])
        try await app.github.edit(top.id) { $0.title = "Newest" }
        await app.tabs.lists.refresh()

        #expect(app.toReview.prefix(3).map(\.number) == [920, 921, 922])
        #expect(app.tabs.lists.listing(in: .toReview).prefix(2).map(\.depth) == [0, 1])
    }

    @Test func aMergedParentDropsOutOfTheStack() async throws {
        let app = try await ConversationApp()
        try await app.github.addCapturedStack()
        await app.tabs.lists.refresh()
        let top = try #require(app.mine.first { $0.number == 278 && $0.repository == "tamarinworks/gazette" })
        app.tabs.open(top)
        let tab = try #require(app.tabs.tab(id: top.id))
        #expect(tab.stackLine != nil)

        // GitHub rebases the next one onto the base once the bottom of a stack merges.
        try await app.github.merge("PR_kwDOAYVX-88AAAABI4ybXQ")
        await app.tabs.lists.refresh()
        #expect(tab.pullRequest.baseRefName == "master")
        #expect(tab.stackLine == nil)
        #expect(tab.mergeFirst == nil)
        #expect(app.tabs.lists.listing(in: .mine).first { $0.id == top.id }?.parent == nil)
    }

    @Test func aMergedParentInNeitherListDropsOutAndIsLetGoWhenItsBranchStays() async throws {
        let app = try await ConversationApp()
        let parent = try await app.github.openPullRequest(number: 930, by: "rowan-ashby")
        let mine = try await app.github.openPullRequest(number: 931, by: FakeGitHub.viewer)
        try await app.github.stack(mine.id, on: parent.id, linked: false)
        await app.tabs.lists.refresh()
        let stacked = try #require(app.mine.first { $0.id == mine.id })
        #expect(app.tabs.lists.stacks.parent(of: stacked)?.id == parent.id)
        #expect(app.tabs.lists.pullRequest(id: parent.id) != nil)

        // Merged with its branch kept, so the PR on it still names that branch as its base.
        try await app.github.merge(parent.id)
        await app.tabs.lists.refresh()
        let listed = try #require(app.mine.first { $0.id == mine.id })
        #expect(listed.baseRefName == parent.headRefName)
        #expect(app.tabs.lists.stacks.isStacked(listed) == false)
        #expect(app.tabs.lists.pullRequest(id: parent.id) == nil)
    }

    @Test func readsGitHubsAnswerToTheStackLookup() async throws {
        let client = GitHubClient(token: { FakeGitHub.validToken }, transport: ProbeTransport(fixture: "stack-neighbours.json"))
        let found = try await client.stackNeighbours(of: ["PR_kwDOAYVX-88AAAABI5AxRA"])

        #expect(found.map(\.number) == [278, 277])
        let top = try #require(found.first)
        let bottom = try #require(found.last)
        #expect(top.stackId == "PRS_kwDOAYVX-84AIiOW")
        #expect(top.stackPosition == 2)
        #expect(top.stackParentId == bottom.id)
        #expect(bottom.stackPosition == 1)
        #expect(bottom.stackParentId == nil)
        #expect(PullRequestStacks(found).line(through: top)?.levels.map { $0.map(\.number) } == [[277], [278]])
    }

    @Test func aGitHubStackIsLookedUpOnceThroughAnyMember() async throws {
        let app = try await ConversationApp()
        try await app.github.addCapturedStack()
        await app.tabs.lists.refresh()

        // One lookup for the captured stack, which finds both, and one each for the fixture's
        // stacks by branch, which find their parents in the list already.
        let lookups = await app.github.stackLookups.last ?? []
        let captured = ["PR_kwDOAYVX-88AAAABI4ybXQ", "PR_kwDOAYVX-88AAAABI5AxRA"]
        #expect(lookups.count { captured.contains($0) } == 1)
    }
}

/// Answers every request with one probe capture, as GitHub answered it.
private struct ProbeTransport: HTTPTransport {
    let fixture: String

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try Data(contentsOf: projectRoot.appending(path: "probe/\(fixture)"))
        return (body, HTTPURLResponse(url: try #require(request.url), statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}
