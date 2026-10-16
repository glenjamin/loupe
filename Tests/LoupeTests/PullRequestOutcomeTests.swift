import Foundation
import LoupeModel
import Testing

struct PullRequestOutcomeTests {
    private let now = Date(timeIntervalSince1970: 1_792_164_120) // Friday 16 Oct 2026, 15:22 UTC
    private let locale = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!

    @Test func saysHowLongAgoAMergeWasWithinTheLastWeek() throws {
        let outcome = try #require(PullRequestOutcome(pullRequest(state: .merged, mergedAt: now.addingTimeInterval(-3 * 3600))))
        #expect(outcome.title == "Merged")
        #expect(outcome.when(now: now, locale: locale, timeZone: utc) == "3 hours ago")
    }

    @Test func givesTheDateAndTimeOfACloseOlderThanAWeek() throws {
        let closedAt = now.addingTimeInterval(-(9 * 24 * 3600 + 20 * 60))
        let outcome = try #require(PullRequestOutcome(pullRequest(state: .closed, closedAt: closedAt)))
        #expect(outcome.title == "Closed")
        #expect(outcome.when(now: now, locale: locale, timeZone: utc) == "7 Oct 2026 at 15:02")
    }

    @Test func tooltipGivesTheFullDateAndTimeEvenWhenRecent() throws {
        let outcome = try #require(PullRequestOutcome(pullRequest(state: .merged, mergedAt: now.addingTimeInterval(-60 * 60))))
        let help = outcome.help(locale: locale, timeZone: utc)
        #expect(help.hasPrefix("Merged Friday"))
        #expect(help.contains("16 October 2026"))
        #expect(help.contains("14:22"))
    }

    @Test func aMergeStoredWithoutItsTimeIsJustMerged() throws {
        let outcome = try #require(PullRequestOutcome(pullRequest(state: .merged)))
        #expect(outcome.when(now: now, locale: locale, timeZone: utc) == nil)
        #expect(outcome.help(locale: locale, timeZone: utc) == "Merged")
    }

    @Test func anOpenPullRequestHasNoOutcome() {
        #expect(PullRequestOutcome(pullRequest(state: .open)) == nil)
    }
}

private func pullRequest(state: PullRequestState, mergedAt: Date? = nil, closedAt: Date? = nil) -> PullRequestSummary {
    PullRequestSummary(
        id: "PR_1", repository: "tamarinworks/loupe", number: 1, title: "A change",
        url: URL(string: "https://github.com/tamarinworks/loupe/pull/1")!, author: "glenjamin", isDraft: false,
        state: state, mergedAt: mergedAt, closedAt: closedAt, reviewDecision: nil, checks: nil,
        updatedAt: Date(timeIntervalSince1970: 0), headRefName: "feature", baseRefName: "main"
    )
}
