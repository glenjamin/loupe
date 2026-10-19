import Foundation
import LoupeGitHub
import LoupeInbox
import LoupeModel
import LoupeStore
import Testing

@MainActor
struct PullRequestListTests {
    @Test func showsBothColumnsNewestFirst() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json", reversed: true)
        let model = try listModel(github)

        await model.refresh()

        #expect(model.error == nil)
        #expect(model.pullRequests(in: .mine).count == 50)
        #expect(model.pullRequests(in: .toReview).count == 13)
        // A stack is listed together, where its newest member goes.
        for list in PullRequestList.allCases {
            var groups: [[PullRequestSummary]] = []
            for listed in model.listing(in: list) {
                if listed.depth > 0, !groups.isEmpty { groups[groups.count - 1].append(listed.pullRequest) } else { groups.append([listed.pullRequest]) }
            }
            let dates = groups.map { $0.map(\.updatedAt).max() ?? .distantPast }
            #expect(dates == dates.sorted(by: >))
        }

        let newest = try #require(model.pullRequests(in: .toReview).first)
        #expect(newest.repository == "tamarinworks/atrium")
        #expect(newest.number == 2928)
        #expect(newest.author == "rowan-ashby")
        #expect(newest.reviewDecision == .reviewRequired)
        #expect(newest.checks == .success)
        #expect(newest.url == URL(string: "https://github.com/tamarinworks/atrium/pull/2928"))
        let served = try #require(await github.pullRequests(in: .toReview).first { $0.id == newest.id })
        #expect(newest.headRefOid == served.headRefOid)
        #expect(newest.baseRefOid == served.baseRefOid)
    }

    @Test func keepsDraftsAndRowsWithoutReviewOrChecks() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)

        await model.refresh()

        let mine = model.pullRequests(in: .mine)
        let draft = try #require(mine.first { $0.repository == "tamarinworks/gazette" && $0.number == 273 })
        #expect(draft.isDraft)
        #expect(draft.reviewDecision == nil)

        let unchecked = try #require(mine.first { $0.repository == "tamarinworks/hadley" && $0.number == 1 })
        #expect(unchecked.checks == nil)
        #expect(unchecked.reviewDecision == .approved)
    }

    @Test func pagesThroughEverySearchResult() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json", maxPageSize: 20)
        let model = try listModel(github)

        await model.refresh()

        #expect(model.error == nil)
        let expected = await github.pullRequests(in: .mine).map(\.id)
        #expect(Set(model.pullRequests(in: .mine).map(\.id)) == Set(expected))
        #expect(expected.count == 50)
        #expect(model.pullRequests(in: .toReview).count == 13)
        // Three pages of mine, one of requests for the viewer's review and one of their reviews.
        #expect(await github.searches.count == 5)
    }

    @Test func rowsCarryEachOfTheirChecksAfterARefresh() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)

        await model.refresh()

        let mine = model.pullRequests(in: .mine)
        // GitHub's rollup says failure, but only through Codecov's tolerated failures.
        let covered = try #require(mine.first { $0.repository == "tamarinworks/gatehouse" && $0.number == 172 })
        #expect(covered.checks == .success)
        #expect(covered.checkContexts.listed == """
            3 of 5 checks passed, 2 coverage failures ignored
            (✗) codecov/patch — 76.92% of diff hit (target 98.23%)
            (✗) codecov/project — 96.01% (-2.22%) compared to 8b4635f
            ✓ ci/circleci: build — Your tests passed on CircleCI!
            ✓ ci/circleci: lint — Your tests passed on CircleCI!
            ✓ ci/circleci: test — Your tests passed on CircleCI!
            """)
        let unchecked = try #require(mine.first { $0.repository == "tamarinworks/hadley" && $0.number == 1 })
        #expect(unchecked.checkContexts.summary == nil)

        // Every open PR's checks are asked for once, in batches GitHub answers well in time.
        let lookups = await github.statusLookups
        #expect(lookups.allSatisfy { $0.count <= 50 })
        let asked = lookups.flatMap(\.self)
        #expect(asked.count == Set(asked).count)
        #expect(Set(asked) == Set((mine + model.pullRequests(in: .toReview)).map(\.id)))
    }

    @Test func rowsSayWhetherTheyConflictWithTheirBaseAfterARefresh() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)

        await model.refresh()

        let mine = model.pullRequests(in: .mine)
        let conflicting = try #require(mine.first { $0.repository == "tamarinworks/bedrock" && $0.number == 2335 })
        #expect(conflicting.mergeable == .conflicting)
        let clean = try #require(mine.first { $0.repository == "tamarinworks/gatehouse" && $0.number == 172 })
        #expect(clean.mergeable == .mergeable)
        // GitHub hadn't worked this one out yet.
        let undecided = try #require(mine.first { $0.repository == "tamarinworks/gazette" && $0.number == 272 })
        #expect(undecided.mergeable == .unknown)

        // Looking a PR up for its other changes doesn't ask again, so keeps what was found.
        try await model.checkForChanges(to: [conflicting.id])
        #expect(model.pullRequest(id: conflicting.id)?.mergeable == .conflicting)
    }

    @Test func checksThatChangeWithoutUpdatingThePullRequestAreFoundOnTheNextRefresh() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let before = try #require(model.pullRequests(in: .toReview).first)
        #expect(before.checks == .success)

        try await github.setChecks(of: before.id, state: "FAILURE", [
            .status("ci/circleci: build", "SUCCESS", description: "Your tests passed on CircleCI!"),
            .status("ci/circleci: test", "PENDING", description: "CircleCI is running your tests"),
            .checkRun("codecov/project", status: "COMPLETED", conclusion: "SKIPPED"),
            .checkRun("codecov/patch", status: "COMPLETED", conclusion: "FAILURE", title: "60.00% of diff hit (target 90.00%)"),
        ])
        await model.refresh()

        let after = try #require(model.pullRequests(in: .toReview).first { $0.id == before.id })
        #expect(after.updatedAt == before.updatedAt)
        #expect(after.checks == .failure)
        #expect(after.checkContexts.listed == """
            1 of 4 checks failed
            ✗ codecov/patch — 60.00% of diff hit (target 90.00%)
            ● ci/circleci: test — CircleCI is running your tests
            ✓ ci/circleci: build — Your tests passed on CircleCI!
            – codecov/project
            """)
    }

    @Test func codecovsProjectCheckFailingAloneLeavesTheChecksPassed() async throws {
        let shown = try await checksShown(state: "FAILURE", [
            .status("ci/circleci: build", "SUCCESS"),
            .checkRun("codecov/project", status: "COMPLETED", conclusion: "FAILURE", title: "96.01% (-2.22%) compared to 8b4635f"),
            .checkRun("codecov/patch", status: "COMPLETED", conclusion: "SUCCESS", title: "100.00% of diff hit (target 96.01%)"),
        ])
        #expect(shown.checks == .success)
        #expect(shown.checkContexts.failedCheckNames.isEmpty)
    }

    @Test func codecovsPatchCheckFailingCountsOnlyBelowTheCoverageWorthALook() async throws {
        let covered = try await checksShown(state: "FAILURE", [
            .status("ci/circleci: build", "SUCCESS"),
            .checkRun("codecov/patch", status: "COMPLETED", conclusion: "FAILURE", title: "76.92% of diff hit (target 98.23%)"),
        ])
        #expect(covered.checks == .success)

        let uncovered = try await checksShown(state: "FAILURE", [
            .status("ci/circleci: build", "SUCCESS"),
            .checkRun("codecov/patch", status: "COMPLETED", conclusion: "FAILURE", title: "65.00% of diff hit (target 98.23%)"),
            .checkRun("codecov/project", status: "COMPLETED", conclusion: "FAILURE", title: "96.01% (-2.22%) compared to 8b4635f"),
        ])
        #expect(uncovered.checks == .failure)
        #expect(uncovered.checkContexts.failedCheckNames == ["patch"])
        #expect(uncovered.checkContexts.summary == "1 of 3 checks failed")
    }

    @Test func codecovsPatchCheckFailingWithoutItsCoverageStillFails() async throws {
        let shown = try await checksShown(state: "FAILURE", [
            .status("ci/circleci: build", "SUCCESS"),
            .checkRun("codecov/patch", status: "COMPLETED", conclusion: "FAILURE"),
        ])
        #expect(shown.checks == .failure)
    }

    @Test func aRealFailureAlongsideCodecovsStillFails() async throws {
        let shown = try await checksShown(state: "FAILURE", [
            .status("ci/circleci: build", "FAILURE", description: "Your tests failed on CircleCI"),
            .checkRun("codecov/project", status: "COMPLETED", conclusion: "FAILURE", title: "96.01% (-2.22%) compared to 8b4635f"),
            .checkRun("codecov/patch", status: "COMPLETED", conclusion: "FAILURE", title: "76.92% of diff hit (target 98.23%)"),
        ])
        #expect(shown.checks == .failure)
        #expect(shown.checkContexts.failedCheckNames == ["build"])
        #expect(shown.checkContexts.listed == """
            1 of 3 checks failed
            ✗ ci/circleci: build — Your tests failed on CircleCI
            (✗) codecov/project — 96.01% (-2.22%) compared to 8b4635f
            (✗) codecov/patch — 76.92% of diff hit (target 98.23%)
            """)
    }

    @Test func aToleratedFailureWhileAnotherCheckRunsLeavesTheChecksPending() async throws {
        let shown = try await checksShown(state: "FAILURE", [
            .status("ci/circleci: test", "PENDING", description: "CircleCI is running your tests"),
            .checkRun("codecov/project", status: "COMPLETED", conclusion: "FAILURE", title: "96.01% (-2.22%) compared to 8b4635f"),
        ])
        #expect(shown.checks == .pending)
        #expect(shown.checkContexts.listed == """
            1 of 2 checks pending
            ● ci/circleci: test — CircleCI is running your tests
            (✗) codecov/project — 96.01% (-2.22%) compared to 8b4635f
            """)
    }

    @Test func aFailureWithNoChecksFetchedToExplainItStaysFailed() async throws {
        let shown = try await checksShown(state: "FAILURE", [])
        #expect(shown.checks == .failure)
    }

    @Test func showsTheListsStoredByThePreviousRunBeforeRefreshing() async throws {
        let directory = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "loupe.sqlite")

        let firstRun = try listModel(try FakeGitHub(fixture: "pr-list.json"), store: PullRequestStore(url: url))
        let refreshStarted = Date.now
        await firstRun.refresh()
        let refreshEnded = Date.now

        let github = try FakeGitHub(fixture: "pr-list.json")
        let secondRun = try listModel(github, store: PullRequestStore(url: url))

        #expect(secondRun.hasStoredLists)
        #expect(secondRun.pullRequests(in: .mine) == firstRun.pullRequests(in: .mine))
        #expect(secondRun.pullRequests(in: .toReview) == firstRun.pullRequests(in: .toReview))
        #expect(secondRun.pullRequests(in: .toReview).first?.checkContexts.isEmpty == false)
        let lastRefreshed = try #require(secondRun.lastRefreshed)
        // The store may keep the time a little coarser than it was taken.
        #expect(refreshStarted.addingTimeInterval(-1) <= lastRefreshed && lastRefreshed <= refreshEnded)
        #expect(await github.requestCount == 0)
    }

    @Test func theFirstLoadAsksForOpenPullRequestsAndLaterOnesForChanges() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)

        await model.refresh()
        let firstLoad = await github.searches
        #expect(firstLoad.count == 3)
        #expect(firstLoad.allSatisfy { $0.contains("is:open") && !$0.contains("updated:") })

        await model.refresh()
        let refresh = await github.searches.dropFirst(firstLoad.count)
        #expect(refresh.count == 3)
        #expect(refresh.allSatisfy { $0.contains("updated:>=") })
        let (reviewed, others) = (refresh.filter { $0.contains("reviewed-by:@me") }, refresh.filter { !$0.contains("reviewed-by:@me") })
        #expect(others.count == 2 && others.allSatisfy { !$0.contains("is:open") })
        #expect(reviewed.count == 1 && reviewed.allSatisfy { $0.contains("is:open") }, "the to-review check finds those merged since")
    }

    @Test func aMergedPullRequestLeavesTheDefaultViewButStaysStored() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let store = try PullRequestStore.inMemory()
        let model = try listModel(github, store: store)
        await model.refresh()
        let merged = try #require(model.pullRequests(in: .mine).last)

        try await github.merge(merged.id)
        await model.refresh()

        #expect(model.error == nil)
        #expect(model.pullRequests(in: .mine).count == 49)
        #expect(!model.pullRequests(in: .mine).contains { $0.id == merged.id })
        let shown = try #require(model.pullRequests(in: .mine, includingClosed: true).first)
        #expect(shown.id == merged.id)
        #expect(shown.state == .merged)
        #expect(shown.mergedAt != nil)
        #expect(try store.snapshot()[.mine].contains { $0.id == merged.id && $0.state == .merged })
    }

    @Test func aRefreshWithNoChangesKeepsEverything() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let mine = model.pullRequests(in: .mine)
        let toReview = model.pullRequests(in: .toReview)

        await model.refresh()

        #expect(model.error == nil)
        #expect(model.pullRequests(in: .mine) == mine)
        #expect(model.pullRequests(in: .toReview) == toReview)
        #expect(mine.count == 50)
        #expect(toReview.count == 13)
    }

    @Test func aRefreshUpdatesChangedPullRequests() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let retitled = try #require(model.pullRequests(in: .mine).last)

        try await github.edit(retitled.id) { $0.title = "Retitled" }
        await model.refresh()

        let updated = try #require(model.pullRequests(in: .mine).first)
        #expect(updated.id == retitled.id)
        #expect(updated.title == "Retitled")
        #expect(model.pullRequests(in: .mine).count == 50)
    }

    @Test func aReviewedPullRequestLeavesToReviewButATeamRequestKeepsOneThere() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json", viewerTeams: ["backend"])
        let model = try listModel(github)
        await model.refresh()
        let toReview = model.pullRequests(in: .toReview)
        let reviewed = toReview[0]
        let teamRequested = toReview[1]

        try await github.edit(reviewed.id) { $0.requestedReviewers = [.user("someone-else")] }
        try await github.edit(teamRequested.id) { $0.requestedReviewers = [.team("backend")] }
        await model.refresh()

        #expect(model.error == nil)
        #expect(!model.pullRequests(in: .toReview, includingClosed: true).contains { $0.id == reviewed.id })
        #expect(model.pullRequests(in: .toReview).contains { $0.id == teamRequested.id })
        #expect(model.pullRequests(in: .toReview).count == 12)
    }

    @Test func anApprovedPullRequestStaysInToReviewUntilMerged() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let approved = try #require(model.pullRequests(in: .toReview).first)
        #expect(model.verdict(on: approved, in: .toReview) == nil)

        try await github.review(approved.id, "APPROVED")
        await model.refresh()

        #expect(model.error == nil)
        let shown = try #require(model.pullRequests(in: .toReview).first { $0.id == approved.id })
        #expect(shown.requestedReviewers == [], "the request was answered")
        #expect(model.verdict(on: shown, in: .toReview) == .approved)
        #expect(model.pullRequests(in: .toReview).count == 13)

        try await github.merge(approved.id)
        await model.refresh()

        #expect(!model.pullRequests(in: .toReview, includingClosed: true).contains { $0.id == approved.id })
        #expect(model.pullRequests(in: .toReview).count == 12)
    }

    @Test func askingForChangesKeepsAPullRequestInToReviewButACommentDoesNotCount() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let toReview = model.pullRequests(in: .toReview)
        let changesAsked = toReview[0]
        let commented = toReview[1]

        try await github.review(changesAsked.id, "CHANGES_REQUESTED")
        try await github.review(commented.id, "COMMENTED")
        await model.refresh()

        let listed = model.pullRequests(in: .toReview)
        let changes = try #require(listed.first { $0.id == changesAsked.id })
        #expect(model.verdict(on: changes, in: .toReview) == .changesRequested)
        let stillAsked = try #require(listed.first { $0.id == commented.id }, "GitHub keeps the request after a comment")
        #expect(model.verdict(on: stillAsked, in: .toReview) == nil)
    }

    @Test func pullRequestsTheViewerReviewedButIsNoLongerAskedAboutAreListed() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let earlier = try await github.openPullRequest(number: 9001, by: "rowan-ashby")
        try await github.review(earlier.id, "APPROVED")
        let commentedOnly = try await github.openPullRequest(number: 9002, by: "rowan-ashby")
        try await github.review(commentedOnly.id, "COMMENTED")
        let model = try listModel(github)

        await model.refresh()

        #expect(model.error == nil)
        let found = try #require(model.pullRequests(in: .toReview).first { $0.id == earlier.id }, "found by the first load")
        #expect(model.verdict(on: found, in: .toReview) == .approved)
        #expect(!model.pullRequests(in: .toReview).contains { $0.id == commentedOnly.id }, "a comment isn't a verdict")

        let later = try await github.openPullRequest(number: 9003, by: "rowan-ashby")
        try await github.review(later.id, "CHANGES_REQUESTED")
        let mine = try #require(model.pullRequests(in: .mine).first)
        try await github.review(mine.id, "COMMENTED")
        await model.refresh()

        #expect(model.pullRequests(in: .toReview).contains { $0.id == later.id }, "found by a refresh's changes")
        #expect(!model.pullRequests(in: .toReview).contains { $0.id == mine.id }, "the viewer's own PRs stay out")
        #expect(model.pullRequests(in: .toReview).count == 15)
    }

    @Test func aDismissedApprovalLeavesToReviewUnlessTheViewerIsAskedAgain() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let toReview = model.pullRequests(in: .toReview)
        let dismissed = toReview[0]
        let reRequested = toReview[1]
        for pullRequest in [dismissed, reRequested] {
            try await github.review(pullRequest.id, "APPROVED")
        }
        await model.refresh()

        try await github.dismissReview(of: dismissed.id)
        try await github.dismissReview(of: reRequested.id)
        try await github.requestReview(of: reRequested.id)
        await model.refresh()

        #expect(!model.pullRequests(in: .toReview, includingClosed: true).contains { $0.id == dismissed.id })
        let asked = try #require(model.pullRequests(in: .toReview).first { $0.id == reRequested.id })
        #expect(model.verdict(on: asked, in: .toReview) == nil)
    }

    @Test func aReRequestAfterAnApprovalWaitsOnTheViewerAgain() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let approved = try #require(model.pullRequests(in: .toReview).first)
        try await github.review(approved.id, "APPROVED")
        await model.refresh()

        try await github.requestReview(of: approved.id)
        await model.refresh()

        let asked = try #require(model.pullRequests(in: .toReview).first)
        #expect(asked.id == approved.id, "back among those awaiting the viewer, newest first")
        #expect(model.verdict(on: asked, in: .toReview) == nil)
    }

    @Test func pullRequestsTheViewerHasGivenAVerdictOnFollowThoseAwaitingThem() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let before = model.pullRequests(in: .toReview)
        let approved = before[5]
        let changesAsked = before[2]

        try await github.review(approved.id, "APPROVED")
        try await github.review(changesAsked.id, "CHANGES_REQUESTED")
        await model.refresh()

        let shown = model.pullRequests(in: .toReview)
        let awaiting = before.map(\.id).filter { ![approved.id, changesAsked.id].contains($0) }
        #expect(shown.prefix(awaiting.count).map(\.id) == awaiting)
        let reviewed = shown.dropFirst(awaiting.count)
        #expect(Set(reviewed.map(\.id)) == [approved.id, changesAsked.id])
        #expect(reviewed.map(\.updatedAt) == reviewed.map(\.updatedAt).sorted(by: >), "newest first")
    }

    @Test func anOldRequestDoesNotHideWhatTheViewerHasJustApproved() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let toReview = model.pullRequests(in: .toReview)
        let approved = toReview[0]
        let stale = toReview[1]
        for pullRequest in [approved, stale] {
            try await github.setRequestEvents(of: pullRequest.id, [.init(reviewer: .user(FakeGitHub.viewer), createdAt: .now - days(100))])
        }

        try await github.review(approved.id, "APPROVED")
        await model.refresh()

        let shown = try #require(model.pullRequests(in: .toReview).first { $0.id == approved.id })
        #expect(!model.isStale(shown, in: .toReview))
        #expect(!model.pullRequests(in: .toReview).contains { $0.id == stale.id })
        #expect(model.staleCount(in: .toReview) == 1)
        #expect(model.pullRequests(in: .toReview).count == 12)
        #expect(model.pullRequests(in: .toReview, includingStale: true).last?.id == stale.id, "hidden ones still come last")
    }

    @Test func aMonthWithoutActivityHidesWhatTheViewerApprovedUntilThereIsSome() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let clock = StoppedClock(at: .now)
        let model = try listModel(github, now: { clock.now })
        await model.refresh()
        let toReview = model.pullRequests(in: .toReview)
        let approved = toReview[0]
        try await github.review(approved.id, "APPROVED")
        await model.refresh()
        let approvedAt = try #require(model.pullRequest(id: approved.id)).updatedAt

        clock.now = approvedAt + days(29)
        #expect(model.pullRequests(in: .toReview).last?.id == approved.id, "listed after those awaiting the viewer")
        #expect(model.staleCount(in: .toReview) == 0)

        // A month on, every other PR has been asked of the viewer again, but the approved one is untouched.
        try await github.passTime(days(31))
        for pullRequest in toReview.dropFirst() {
            try await github.requestReview(of: pullRequest.id)
        }
        await model.refresh()
        clock.now = approvedAt + days(31)
        let shown = try #require(model.pullRequest(id: approved.id))
        #expect(model.verdict(on: shown, in: .toReview) == .approved)
        #expect(model.isStale(shown, in: .toReview))
        #expect(!model.pullRequests(in: .toReview).contains { $0.id == approved.id })
        #expect(model.pullRequests(in: .toReview).count == toReview.count - 1)
        #expect(model.staleCount(in: .toReview) == 1)
        #expect(model.pullRequests(in: .toReview, includingStale: true).last?.id == approved.id, "after the recent ones")

        try await github.edit(approved.id) { $0.title += " (rebased)" }
        await model.refresh()

        #expect(model.pullRequests(in: .toReview).last?.id == approved.id, "back after those awaiting the viewer")
        #expect(model.staleCount(in: .toReview) == 0)
    }

    @Test func aPullRequestTheViewerApprovedJoinsToReviewWhenLookedUp() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let approved = try await github.openPullRequest(number: 9001, by: "rowan-ashby")
        try await github.review(approved.id, "APPROVED")

        try await model.checkForChanges(to: [approved.id])

        let shown = try #require(model.pullRequests(in: .toReview).first { $0.id == approved.id })
        #expect(model.verdict(on: shown, in: .toReview) == .approved)
        #expect(model.reviewMark(on: shown, in: .toReview)?.kind == .approved, "with the viewer's latest review")
    }

    @Test func pullRequestsAwaitingAFirstReviewSayNothingOfOne() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()

        let toReview = model.pullRequests(in: .toReview)
        #expect(!toReview.isEmpty)
        #expect(toReview.allSatisfy { model.reviewMark(on: $0, in: .toReview) == nil })
        #expect(model.pullRequests(in: .mine).allSatisfy { model.reviewMark(on: $0, in: .mine) == nil })
    }

    @Test func anApprovalSaysSoUntilCommitsArePushedOnTopOfIt() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let approved = try #require(model.pullRequests(in: .toReview).first)
        try await github.review(approved.id, "APPROVED")
        await model.refresh()

        let checked = try #require(model.pullRequest(id: approved.id))
        let unchanged = try #require(model.reviewMark(on: checked, in: .toReview))
        #expect(unchanged.kind == .approved)
        #expect(!unchanged.isUpdated, "nothing pushed since")

        await github.passTime(60)
        try await github.push(to: approved.id, commits: 2)
        await model.refresh()

        let shown = try #require(model.pullRequest(id: approved.id))
        let updated = try #require(model.reviewMark(on: shown, in: .toReview))
        #expect(updated.kind == .approved, "the verdict still shows")
        #expect(updated.updates.count == 1)
        guard case let .commits(count, lastCommittedAt) = try #require(updated.updates.first) else {
            Issue.record("expected commits since, got \(updated.updates)")
            return
        }
        #expect(count == 2)
        #expect(try #require(lastCommittedAt) > (try #require(updated.reviewedAt)))
        #expect(model.verdict(on: shown, in: .toReview) == .approved, "still waiting on its author or a merge")
    }

    @Test func aCommentSaysTheViewerReviewedUntilSomethingIsPushed() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let commented = try #require(model.pullRequests(in: .toReview).first)
        try await github.review(commented.id, "COMMENTED")
        await model.refresh()

        var shown = try #require(model.pullRequest(id: commented.id))
        let unchanged = try #require(model.reviewMark(on: shown, in: .toReview))
        #expect(unchanged.kind == .commented)
        #expect(!unchanged.isUpdated, "the request it still has came before the comment")
        #expect(model.verdict(on: shown, in: .toReview) == nil, "still waiting on the viewer")

        await github.passTime(60)
        try await github.push(to: commented.id)
        await model.refresh()

        shown = try #require(model.pullRequest(id: commented.id))
        let pushed = try #require(model.reviewMark(on: shown, in: .toReview))
        #expect(pushed.kind == .commented)
        guard case .commits(1, _) = try #require(pushed.updates.first) else {
            Issue.record("expected a commit since, got \(pushed.updates)")
            return
        }

        await github.passTime(60)
        try await github.forcePush(commented.id)
        await model.refresh()

        shown = try #require(model.pullRequest(id: commented.id))
        let forcePushed = try #require(model.reviewMark(on: shown, in: .toReview))
        guard case let .forcePushed(at) = try #require(forcePushed.updates.first) else {
            Issue.record("expected a force-push since, got \(forcePushed.updates)")
            return
        }
        #expect(at > (try #require(forcePushed.reviewedAt)))
    }

    @Test func askingTheViewerAgainAfterTheirReviewCountsAsAnUpdate() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let approved = try #require(model.pullRequests(in: .toReview).first)
        try await github.review(approved.id, "APPROVED")
        await model.refresh()

        await github.passTime(60)
        try await github.requestReview(of: approved.id)
        await model.refresh()

        let shown = try #require(model.pullRequest(id: approved.id))
        let mark = try #require(model.reviewMark(on: shown, in: .toReview))
        #expect(mark.kind == .approved, "what the viewer said last time still shows")
        #expect(mark.updates == [.reRequested(at: try #require(shown.reviewRequestedAt))])
        #expect(model.verdict(on: shown, in: .toReview) == nil, "back among those awaiting the viewer")
    }

    @Test func theCheckReadsACommentOnlyReviewAndTheForcePushSinceAsGitHubAnswers() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        await github.fail(with: try .fixture("review-requests.json"))
        let atrium2202 = "PR_kwDODst66c6unjHc"

        let requests = try await github.client().reviewRequests(for: [atrium2202, "PR_kwDOB75F5s7-Gq3V"])

        let reviewed = try #require(requests[atrium2202]?.viewerLatestReview)
        #expect(reviewed.state == .commented)
        #expect(reviewed.commitOid == "051572930114d87f8dcc78cf71d087d1a6d76fa7")
        #expect(reviewed.commitsSince == nil, "force-pushed away from the reviewed commit")
        #expect(reviewed.forcePushedAt == (try Date("2025-10-28T16:28:53Z", strategy: .iso8601)), "the last push after the review")
        #expect(requests["PR_kwDOB75F5s7-Gq3V"]?.viewerLatestReview == nil, "not reviewed")
    }

    @Test func aReviewDoesNotChangeWhenARequestIsHiddenAsStale() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let commented = try #require(model.pullRequests(in: .toReview).first)
        try await github.setRequestEvents(of: commented.id, [.init(reviewer: .user(FakeGitHub.viewer), createdAt: .now - days(100))])
        try await github.review(commented.id, "COMMENTED")
        await model.refresh()

        let shown = try #require(model.pullRequest(id: commented.id))
        #expect(model.isStale(shown, in: .toReview), "the request's age decides, as before")
        #expect(model.staleCount(in: .toReview) == 1)
        #expect(!model.pullRequests(in: .toReview).contains { $0.id == commented.id })
        #expect(model.pullRequests(in: .toReview, includingStale: true).last?.id == commented.id)
        #expect(model.reviewMark(on: shown, in: .toReview)?.kind == .commented, "labelled once shown")
    }

    @Test func eachPullRequestSaysWhoItsReviewWaitsOn() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let store = try PullRequestStore.inMemory()
        let model = try listModel(github, store: store)
        await model.refresh()
        let mine = try #require(model.pullRequests(in: .mine).first)
        let toReview = try #require(model.pullRequests(in: .toReview).first)
        #expect(mine.requestedReviewers == [])
        #expect(toReview.requestedReviewers == [.user(login: FakeGitHub.viewer)])

        try await github.edit(mine.id) { $0.requestedReviewers = [.user("kit-vance"), .team("devs")] }
        await model.refresh()
        let asked: [RequestedReviewer] = [.user(login: "kit-vance"), .team(slug: "devs")]
        #expect(model.pullRequest(id: mine.id)?.requestedReviewers == asked, "in GitHub's order")
        #expect(try listModel(github, store: store).pullRequest(id: mine.id)?.requestedReviewers == asked, "kept for the next launch")

        // kit-vance reviews, which ends their request.
        try await github.edit(mine.id) { $0.requestedReviewers = [.team("devs")] }
        await model.refresh()
        #expect(model.pullRequest(id: mine.id)?.requestedReviewers == [.team(slug: "devs")])
    }

    @Test func aReviewRequestOverThreeMonthsOldIsHiddenAndCounted() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let toReview = model.pullRequests(in: .toReview)
        let stale = toReview[0]
        let recent = toReview[1]

        try await github.setRequestEvents(of: stale.id, [.init(reviewer: .user(FakeGitHub.viewer), createdAt: .now - days(31))])
        try await github.setRequestEvents(of: recent.id, [.init(reviewer: .user(FakeGitHub.viewer), createdAt: .now - days(29))])
        await model.refresh()

        #expect(model.error == nil)
        #expect(!model.pullRequests(in: .toReview).contains { $0.id == stale.id })
        #expect(model.pullRequests(in: .toReview).contains { $0.id == recent.id })
        #expect(model.pullRequests(in: .toReview).count == 12)
        #expect(model.staleCount(in: .toReview) == 1)
        #expect(model.pullRequests(in: .mine).count == 50, "the viewer's own PRs aren't requests")
        #expect(model.staleCount(in: .mine) == 0)
    }

    @Test func askingForHiddenRequestsListsThemAfterTheRecentOnes() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let recent = model.pullRequests(in: .toReview)
        let older = recent[0]
        let oldest = recent[1]
        try await github.setRequestEvents(of: older.id, [.init(reviewer: .user(FakeGitHub.viewer), createdAt: .now - days(100))])
        try await github.setRequestEvents(of: oldest.id, [.init(reviewer: .user(FakeGitHub.viewer), createdAt: .now - days(200))])
        await model.refresh()

        let shown = model.pullRequests(in: .toReview, includingStale: true)

        #expect(shown.map(\.id) == model.pullRequests(in: .toReview).map(\.id) + [older.id, oldest.id], "newest first, after the recent ones")
        #expect(model.staleCount(in: .toReview) == 2)
        #expect(model.pullRequests(in: .toReview).count == 11)
        #expect(model.pullRequests(in: .mine, includingStale: true) == model.pullRequests(in: .mine))
    }

    @Test func theViewersLatestRequestCountsNotSomeoneElses() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        try await github.replayRequestEvents(fromProbe: "review-requests.json")
        let clock = StoppedClock(at: try Date("2026-10-16T12:00:00Z", strategy: .iso8601))
        let model = try listModel(github, now: { clock.now })

        await model.refresh()

        // Re-requested, so the later of two.
        let lift = try #require(model.pullRequest(id: "PR_kwDOTPMj4M8AAAABABV3wg"))
        #expect(lift.reviewRequestedAt == (try Date("2026-08-17T16:25:20Z", strategy: .iso8601)))
        // The viewer's request, not the later one of rowan-ashby.
        let bedrock = try #require(model.pullRequest(id: "PR_kwDOB75F5s7-Gq3V"))
        #expect(bedrock.reviewRequestedAt == (try Date("2026-08-12T14:43:47Z", strategy: .iso8601)))
        // Every request in the probe, all from August or earlier, had waited over a month by then.
        #expect(model.staleCount(in: .toReview) == 6)
        #expect(model.pullRequests(in: .toReview).count == 7)
    }

    @Test func aReRequestBringsBackAPullRequestHiddenForAnOldRequest() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let old = try #require(model.pullRequests(in: .toReview).first)
        try await github.setRequestEvents(of: old.id, [.init(reviewer: .user(FakeGitHub.viewer), createdAt: .now - days(120))])
        await model.refresh()
        #expect(!model.pullRequests(in: .toReview).contains { $0.id == old.id })

        try await github.requestReview(of: old.id, at: .now - days(1))
        await model.refresh()

        #expect(model.pullRequests(in: .toReview).contains { $0.id == old.id })
        #expect(model.staleCount(in: .toReview) == 0)
    }

    @Test func withNoRequestOnRecordThePullRequestsUpdateTimeIsItsAge() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let clock = StoppedClock(at: .now)
        let store = try PullRequestStore.inMemory()
        let model = try listModel(github, store: store, now: { clock.now })
        await model.refresh()
        let unrecorded = try #require(model.pullRequests(in: .toReview).last)
        try await github.setRequestEvents(of: unrecorded.id, [])

        clock.now = unrecorded.updatedAt + days(29)
        await model.refresh()
        let shown = try #require(model.pullRequests(in: .toReview).first { $0.id == unrecorded.id })
        #expect(shown.reviewRequestedAt == nil)

        clock.now = unrecorded.updatedAt + days(31)
        #expect(!model.pullRequests(in: .toReview).contains { $0.id == unrecorded.id })
        // Hidden, not forgotten: still stored, and shown again by a clock that says it's younger.
        #expect(try store.snapshot()[.toReview].contains { $0.id == unrecorded.id })
        #expect(model.pullRequest(id: unrecorded.id) != nil)
        clock.now = unrecorded.updatedAt + days(29)
        #expect(model.pullRequests(in: .toReview).contains { $0.id == unrecorded.id })
    }

    @Test func aPullRequestThatCanNoLongerBeFoundLeavesToReview() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let deleted = try #require(model.pullRequests(in: .toReview).first)

        await github.delete(deleted.id)
        await model.refresh()

        #expect(model.error == nil)
        #expect(!model.pullRequests(in: .toReview).contains { $0.id == deleted.id })
        #expect(model.pullRequests(in: .toReview).count == 12)
    }

    @Test func theRefreshTimeAdvancesOnlyWhenARefreshSucceeds() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let store = try PullRequestStore.inMemory()
        let model = try listModel(github, store: store)
        await model.refresh()
        let loaded = try store.snapshot()
        let lastRefreshed = try #require(model.lastRefreshed)

        await github.fail(with: .status(502))
        await model.refresh()
        #expect(model.lastRefreshed == lastRefreshed)

        await github.recover()
        let searchesBefore = await github.searches.count
        await model.refresh()

        #expect(model.error == nil)
        #expect(try #require(model.lastRefreshed) > lastRefreshed)
        // Changes are still asked for from just before the last successful refresh.
        for search in await github.searches.dropFirst(searchesBefore) {
            let list: PullRequestList = search.contains(" author:@me") ? .mine : .toReview
            let refreshedAt = try #require(loaded.refreshedAt(list))
            let since = try Date(String(try #require(search.firstMatch(of: /updated:>=(\S+)/)).1), strategy: .iso8601)
            #expect(since <= refreshedAt.addingTimeInterval(-120))
            #expect(since > refreshedAt.addingTimeInterval(-121))
        }
    }

    @Test func aFailedRefreshKeepsTheStoredListsAndReportsTheError() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let mine = model.pullRequests(in: .mine)
        let toReview = model.pullRequests(in: .toReview)
        let lastRefreshed = model.lastRefreshed

        await github.fail(with: .status(502))
        await model.refresh()

        #expect(model.error == "GitHub returned HTTP 502")
        #expect(model.pullRequests(in: .mine) == mine)
        #expect(model.pullRequests(in: .toReview) == toReview)
        #expect(model.lastRefreshed == lastRefreshed)

        await github.recover()
        await model.refresh()

        #expect(model.error == nil)
        #expect(try #require(model.lastRefreshed) > #require(lastRefreshed))
    }

    @Test func aRejectedTokenOnFirstLaunchShowsAnError() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github, token: "expired")

        await model.refresh()

        #expect(!model.hasStoredLists)
        #expect(model.error == "GitHub returned HTTP 401: Bad credentials")
    }

    @Test func aGraphQLErrorShowsAnError() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        await github.fail(with: try .fixture("graphql-error.json"))
        let model = try listModel(github)

        await model.refresh()

        #expect(!model.hasStoredLists)
        #expect(model.error == "GitHub query failed: Field 'nonexistentField' doesn't exist on type 'User'")
    }

    @Test func aMissingGitHubLoginShowsAnError() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let client = github.client { throw GitHubError.token("not logged in to any GitHub hosts") }
        let model = try PullRequestListModel(client: client, store: .inMemory(), checkoutSearchRoots: [], onOpen: { _ in })

        await model.refresh()

        #expect(!model.hasStoredLists)
        #expect(model.error == "Couldn't get a GitHub token from `gh auth token`: not logged in to any GitHub hosts")
        #expect(await github.requestCount == 0)
    }

    @Test func refreshesOnReturnOnlyOnceTheListsAreStale() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let store = try PullRequestStore.inMemory()
        try await listModel(github, store: store).refresh()
        let requestsForOneRefresh = await github.requestCount

        try await listModel(github, store: store, staleAfter: .seconds(300)).refreshIfStale()
        #expect(await github.requestCount == requestsForOneRefresh)

        try await listModel(github, store: store, staleAfter: .zero).refreshIfStale()
        #expect(await github.requestCount > requestsForOneRefresh)
    }

    @Test func aListedPullRequestIsBeingCheckedWhileARefreshWaitsOnGitHub() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let model = try listModel(github)
        await model.refresh()
        let listed = try #require(model.pullRequests(in: .mine).first)
        #expect(!model.isChecking(listed.id))

        await github.hold(.search)
        let refreshing = Task { await model.refresh() }
        await github.arrival(of: .search)
        #expect(model.isChecking(listed.id))

        await github.release(.search)
        await refreshing.value
        #expect(!model.isChecking(listed.id))
    }

    // Only catches a loop that never sleeps, so it outlasts a whole suite run on a busy machine.
    @Test(.timeLimit(.minutes(5)))
    func refreshesEachIntervalUntilCancelled() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        let clock = ManualClock()
        let model = try listModel(github, refreshInterval: .seconds(180), sleep: { try await clock.sleep(for: $0) })

        let refreshing = Task { await model.keepRefreshed() }
        defer { refreshing.cancel() }
        try await clock.untilAsleep()
        #expect(model.hasStoredLists)
        var requests = await github.requestCount
        for _ in 1...3 {
            try await clock.advance()
            let after = await github.requestCount
            #expect(after > requests, "each interval refreshes again")
            requests = after
        }
        #expect(clock.sleeps == Array(repeating: .seconds(180), count: 4))

        refreshing.cancel()
        await refreshing.value
        #expect(await github.requestCount == requests, "nothing refreshes once cancelled")
    }

    @Test func openingAPullRequestHandsItToTheSelectionHandler() async throws {
        let github = try FakeGitHub(fixture: "pr-list.json")
        var opened: [URL] = []
        let model = try PullRequestListModel(client: github.client(), store: .inMemory(), checkoutSearchRoots: [], onOpen: { opened.append($0.url) })
        await model.refresh()

        let pullRequest = try #require(model.pullRequests(in: .toReview).first)
        model.open(pullRequest)

        #expect(opened == [pullRequest.url])
    }
}

/// The PR as listed after a refresh that finds GitHub reporting `state` over `contexts` for
/// its head commit.
@MainActor
private func checksShown(state: String, _ contexts: [FakeCheckContext]) async throws -> PullRequestSummary {
    let github = try FakeGitHub(fixture: "pr-list.json")
    let model = try listModel(github)
    await model.refresh()
    let id = try #require(model.pullRequests(in: .toReview).first).id
    try await github.setChecks(of: id, state: state, contexts)
    await model.refresh()
    return try #require(model.pullRequests(in: .toReview).first { $0.id == id })
}

@MainActor
private func listModel(
    _ github: FakeGitHub,
    token: String = FakeGitHub.validToken,
    store: PullRequestStore? = nil,
    refreshInterval: Duration = .seconds(180),
    staleAfter: Duration = .seconds(300),
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
    now: @escaping @MainActor () -> Date = { .now }
) throws -> PullRequestListModel {
    try PullRequestListModel(
        client: github.client(token: token),
        store: store ?? .inMemory(),
        refreshInterval: refreshInterval,
        staleAfter: staleAfter,
        sleep: sleep,
        checkoutSearchRoots: [],
        now: now,
        onOpen: { _ in }
    )
}

private func days(_ count: Double) -> TimeInterval {
    count * 24 * 60 * 60
}

/// A time that moves only when the test sets it.
@MainActor
private final class StoppedClock {
    var now: Date

    init(at now: Date) {
        self.now = now
    }
}

/// Stands in for the clock the refresh loop sleeps on: a sleep lasts until the test advances
/// time past it, or the sleeping task is cancelled.
@MainActor
private final class ManualClock {
    /// How long each sleep asked for, in order.
    private(set) var sleeps: [Duration] = []
    private var sleeper: CheckedContinuation<Void, Error>?
    private var waiter: CheckedContinuation<Void, Error>?

    func sleep(for duration: Duration) async throws {
        sleeps.append(duration)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                sleeper = $0
                waiter?.resume()
                waiter = nil
            }
        } onCancel: {
            Task { @MainActor in self.wake(throwing: CancellationError()) }
        }
    }

    /// Ends the current sleep, as if its time had passed, and waits for the next one.
    func advance() async throws {
        wake(throwing: nil)
        try await untilAsleep()
    }

    /// Waits for the loop to sleep, however long its refresh takes; the test's time limit
    /// catches a loop that never does.
    func untilAsleep() async throws {
        guard sleeper == nil else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiter = $0 }
        } onCancel: {
            Task { @MainActor in self.stopWaiting() }
        }
    }

    private func wake(throwing error: (any Error)?) {
        guard let sleeper else { return }
        self.sleeper = nil
        if let error { sleeper.resume(throwing: error) } else { sleeper.resume() }
    }

    private func stopWaiting() {
        waiter?.resume(throwing: CancellationError())
        waiter = nil
    }
}

private extension [CheckContext] {
    /// The summary over a line per check in the order they're listed, to compare at a glance.
    var listed: String {
        ([summary ?? ""] + failingFirst.map { check in
            let glyph = check.isToleratedFailure ? "(\(check.status.glyph))" : check.status.glyph
            let line = "\(glyph) \(check.name)"
            guard let description = check.description, !description.isEmpty else { return line }
            return "\(line) — \(description)"
        }).joined(separator: "\n")
    }
}

private extension CheckStatus {
    var glyph: String {
        switch self {
        case .success: "✓"
        case .failure: "✗"
        case .pending: "●"
        case .neutral: "–"
        }
    }
}
