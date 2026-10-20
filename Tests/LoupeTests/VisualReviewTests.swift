import Foundation
import LoupeModel
import Testing

struct VisualReviewTests {
    @Test func readsCIsDiffBookComment() throws {
        let review = try #require(VisualReview(commentId: "IC_1", markdown: diffBookComment, updatedAt: edited))

        #expect(review.title == "Visual baselines changed")
        #expect(review.reportURL.absoluteString == "https://output.circle-artifacts.com/output/job/11111111-2222-4333-8444-555555555555/artifacts/0/diff-book/review/index.html")
        #expect(review.artifactsURL?.absoluteString == "https://app.circleci.com/pipelines/github/tamarinworks/marmot/41230/workflows/66666666-7777-4888-9999-aaaaaaaaaaaa/jobs/301122/artifacts")
        #expect(review.counts == VisualReview.Counts(changed: 4, new: 0, removed: 0))
        #expect(review.changeCount == 4)
        #expect(review.hasChanges)
        #expect(review.stories.map(\.name) == [
            "integrations-sheets-widget-configuration-preview--primary",
            "visualizations-legacy--classic",
            "visualizations-legacy--fixies",
            "visualizations-linechart--cumulative",
        ])
        #expect(review.stories.allSatisfy { $0.status == .changed })
        #expect(review.rendered == VisualReview.Rendered(count: 524, total: 593))
        #expect(review.updatedAt == edited)
    }

    @Test func anyOtherCommentIsNotOne() {
        #expect(VisualReview(commentId: "IC_1", markdown: "Looks good, [see the report](https://example.com/index.html)", updatedAt: edited) == nil)
    }

    @Test func aMarkedCommentWithNoLinkHasNoReport() {
        #expect(VisualReview(commentId: "IC_1", markdown: "<!-- diff-book-review -->\n### Visual baselines changed\n\nThe report failed to build.", updatedAt: edited) == nil)
    }

    @Test func reworded() throws {
        let markdown = """
            <!-- diff-book-review -->
            ## Screenshots differ

            Three stories look different now: 1 changed, 1 new and 1 removed.

            [Report](https://output.circle-artifacts.com/output/job/11111111-2222-4333-8444-555555555555/artifacts/0/diff-book/review/index.html) · [all artifacts](https://app.circleci.com/pipelines/github/tamarinworks/marmot/41230/workflows/66666666-7777-4888-9999-aaaaaaaaaaaa/jobs/301122/artifacts)

            * `buttons--primary`: changed
            * `buttons--ghost` - added
            * `legacy--old` -- deleted
            * `charts--bar` — flaky
            """
        let review = try #require(VisualReview(commentId: "IC_1", markdown: markdown, updatedAt: edited))

        #expect(review.title == "Screenshots differ")
        #expect(review.reportURL.lastPathComponent == "index.html")
        #expect(review.artifactsURL?.lastPathComponent == "artifacts")
        #expect(review.counts == VisualReview.Counts(changed: 1, new: 1, removed: 1))
        #expect(review.stories.map(\.status) == [.changed, .new, .removed, .other("flaky")])
        #expect(review.rendered == nil)
    }

    @Test func wordingItCantCountStillGivesTheReport() throws {
        let markdown = """
            <!-- diff-book-review -->
            Some baselines moved. **[Have a look](https://output.circle-artifacts.com/output/job/11111111-2222-4333-8444-555555555555/artifacts/0/diff-book/review/index.html)**.
            """
        let review = try #require(VisualReview(commentId: "IC_1", markdown: markdown, updatedAt: edited))

        #expect(review.reportURL.lastPathComponent == "index.html")
        #expect(review.counts == nil)
        #expect(review.stories.isEmpty)
        #expect(review.changeCount == nil)
        #expect(review.hasChanges, "something to look at, as far as anyone can tell")
    }

    @Test func noChanges() throws {
        let markdown = """
            <!-- diff-book-review -->
            ### No visual changes

            0 baseline(s) on this branch differ from `master`: 0 changed, 0 new, 0 removed.

            **[Open the review report](https://output.circle-artifacts.com/output/job/11111111-2222-4333-8444-555555555555/artifacts/0/diff-book/review/index.html)**
            """
        let review = try #require(VisualReview(commentId: "IC_1", markdown: markdown, updatedAt: edited))

        #expect(review.changeCount == 0)
        #expect(!review.hasChanges)
    }

    @Test func theLatestOfSeveralIsTheMostRecentlyUpdated() throws {
        let older = Date(timeIntervalSince1970: 1_790_000_000)
        let items = [
            comment("IC_1", markdown: diffBookComment, made: older, updated: edited),
            comment("IC_2", markdown: "Thanks!", made: older, updated: older.addingTimeInterval(9_000)),
            comment("IC_3", markdown: diffBookComment.replacing("4 changed", with: "3 changed"), made: older.addingTimeInterval(60), updated: older.addingTimeInterval(120)),
            TimelineItem(id: "C_1", date: edited.addingTimeInterval(60), actor: nil, event: .commit(oid: "abc", headline: "Later commit")),
        ]

        #expect(VisualReview.latest(in: items)?.commentId == "IC_1", "edited in place after the other was made")
        #expect(VisualReview.latest(in: Array(items.dropFirst()))?.commentId == "IC_3")
        #expect(VisualReview.latest(in: [items[1], items[3]]) == nil)
    }
}

private let edited = Date(timeIntervalSince1970: 1_792_500_000)

private func comment(_ id: String, markdown: String, made: Date, updated: Date) -> TimelineItem {
    TimelineItem(id: id, date: made, actor: Participant(login: "tamarindeployer", avatarURL: nil), event: .comment(bodyHTML: "", isMinimized: false), body: markdown, updatedAt: updated)
}

/// CI's comment as posted on a marmot PR, captured in `probe/diff-book-comment.json` with its
/// ids made up.
let diffBookComment: String = {
    struct Comment: Decodable { let body: String }
    let data = (try? Data(contentsOf: projectRoot.appending(path: "probe/diff-book-comment.json"))) ?? Data()
    return (try? JSONDecoder().decode(Comment.self, from: data))?.body ?? ""
}()
