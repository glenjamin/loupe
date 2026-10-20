import Foundation
import LoupeModel
import Testing

struct PullRequestLinkTests {
    @Test(arguments: [
        "https://github.com/tamarinworks/porter/pull/1522",
        "https://github.com/tamarinworks/porter/pull/1522/",
        "https://github.com/tamarinworks/porter/pull/1522/files",
        "https://github.com/tamarinworks/porter/pull/1522/commits/ef1f2b240f2b7ec367ddd2b5e8026b696d544838",
        "https://github.com/tamarinworks/porter/pull/1522#issuecomment-3412345678",
        "https://github.com/tamarinworks/porter/pull/1522#discussion_r2412345678",
        "https://github.com/tamarinworks/porter/pull/1522/files?w=1#diff-abc",
        "http://www.github.com/tamarinworks/porter/pull/1522",
        "HTTPS://GitHub.com/tamarinworks/porter/pull/1522",
        "loupe://github.com/tamarinworks/porter/pull/1522",
        "loupe://github.com/tamarinworks/porter/pull/1522/files#discussion_r2412345678",
        "loupe://www.github.com/tamarinworks/porter/pull/1522",
        "LOUPE://GitHub.com/tamarinworks/porter/pull/1522",
        "loupe:///tamarinworks/porter/pull/1522",
        "loupe:///tamarinworks/porter/pull/1522/files",
    ])
    func findsThePullRequestWhicheverPartOfItALinkPointsAt(_ link: String) throws {
        let url = try #require(URL(string: link))
        let found = try #require(PullRequestLink(url: url))
        #expect(found.repository == "tamarinworks/porter")
        #expect(found.number == 1522)
    }

    @Test(arguments: [
        ("https://github.com/tamarinworks/porter/pull/1522", nil),
        ("https://github.com/tamarinworks/porter/pull/1522#issuecomment-5829229341", .comment(5_829_229_341)),
        ("https://github.com/tamarinworks/porter/pull/1522?via=loupe#issuecomment-5829229341", .comment(5_829_229_341)),
        ("https://github.com/tamarinworks/porter/pull/1522#pullrequestreview-5552533813", .review(5_552_533_813)),
        ("https://github.com/tamarinworks/porter/pull/1522#discussion_r4298372143", .reviewComment(4_298_372_143)),
        ("https://github.com/tamarinworks/porter/pull/1522/files#r4298372143", .reviewComment(4_298_372_143)),
        ("https://github.com/tamarinworks/porter/pull/1522/files/ef1f2b240f2b7ec367ddd2b5e8026b696d544838#r4298372143", .reviewComment(4_298_372_143)),
        ("https://github.com/tamarinworks/porter/pull/1522/changes#r4298372143", .reviewComment(4_298_372_143)),
        ("https://github.com/tamarinworks/porter/pull/1522/files", .files(commit: nil, fileHash: nil)),
        ("https://github.com/tamarinworks/porter/pull/1522/changes", .files(commit: nil, fileHash: nil)),
        ("https://github.com/tamarinworks/porter/pull/1522/files#diff-\(appGoHash)", .files(commit: nil, fileHash: appGoHash)),
        ("https://github.com/tamarinworks/porter/pull/1522/files#diff-\(appGoHash)R12", .files(commit: nil, fileHash: appGoHash)),
        ("https://github.com/tamarinworks/porter/pull/1522/files?w=1#diff-\(appGoHash)L3-R5", .files(commit: nil, fileHash: appGoHash)),
        ("https://github.com/tamarinworks/porter/pull/1522/files#diff-abc", .files(commit: nil, fileHash: nil)),
        ("https://github.com/tamarinworks/porter/pull/1522/files/ef1f2b240f2b7ec367ddd2b5e8026b696d544838", .files(commit: "ef1f2b240f2b7ec367ddd2b5e8026b696d544838", fileHash: nil)),
        ("https://github.com/tamarinworks/porter/pull/1522/files/ef1f2b2..48b41de", .files(commit: nil, fileHash: nil)),
        ("https://github.com/tamarinworks/porter/pull/1522/changes/ef1f2b2", .files(commit: "ef1f2b2", fileHash: nil)),
        ("https://github.com/tamarinworks/porter/pull/1522/commits/ef1f2b240f2b7ec367ddd2b5e8026b696d544838", .files(commit: "ef1f2b240f2b7ec367ddd2b5e8026b696d544838", fileHash: nil)),
        ("https://github.com/tamarinworks/porter/pull/1522/commits/ef1f2b240f2b7ec367ddd2b5e8026b696d544838#diff-\(appGoHash)", .files(commit: "ef1f2b240f2b7ec367ddd2b5e8026b696d544838", fileHash: appGoHash)),
        ("https://github.com/tamarinworks/porter/pull/1522/commits", nil),
        ("https://github.com/tamarinworks/porter/pull/1522/checks", nil),
        ("https://github.com/tamarinworks/porter/pull/1522#top", nil),
        ("https://github.com/tamarinworks/porter/pull/1522#issuecomment-", nil),
        ("loupe://github.com/tamarinworks/porter/pull/1522#issuecomment-5829229341", .comment(5_829_229_341)),
        ("loupe:///tamarinworks/porter/pull/1522#pullrequestreview-5552533813", .review(5_552_533_813)),
        ("loupe:///tamarinworks/porter/pull/1522#discussion_r4298372143", .reviewComment(4_298_372_143)),
        ("loupe:///tamarinworks/porter/pull/1522/files#diff-\(appGoHash)", .files(commit: nil, fileHash: appGoHash)),
        ("loupe:///tamarinworks/porter/pull/1522/commits/ef1f2b2", .files(commit: "ef1f2b2", fileHash: nil)),
    ] as [(String, PullRequestLink.Target?)])
    func namesThePartOfThePullRequestItPointsAtWhereLoupeHasAPlaceForIt(_ link: String, _ target: PullRequestLink.Target?) throws {
        let url = try #require(URL(string: link))
        let found = try #require(PullRequestLink(url: url))
        #expect(found.target == target)
        #expect(found.repository == "tamarinworks/porter")
        #expect(found.number == 1522)
    }

    @Test(arguments: [
        "https://github.com/tamarinworks/porter/issues/1522",
        "https://github.com/tamarinworks/porter/commit/ef1f2b240f2b7ec367ddd2b5e8026b696d544838",
        "https://github.com/tamarinworks/porter/compare/master...feature",
        "https://github.com/tamarinworks/porter/pulls",
        "https://github.com/tamarinworks/porter/pull/",
        "https://github.com/tamarinworks/porter/pull/new/feature",
        "https://github.com/tamarinworks/porter/pull/+1522",
        "https://github.com/tamarinworks/porter",
        "https://github.com/",
        "https://gist.github.com/tamarinworks/porter/pull/1522",
        "https://api.github.com/repos/tamarinworks/porter/pulls/1522",
        "https://example.com/tamarinworks/porter/pull/1522",
        "mailto:someone@example.com",
        "ftp://github.com/tamarinworks/porter/pull/1522",
        "loupe://example.com/tamarinworks/porter/pull/1522",
        "loupe://tamarinworks/porter/pull/1522",
        "loupe:///tamarinworks/porter/issues/1522",
        "loupe:///tamarinworks/porter",
        "loupe:",
    ])
    func anyOtherLinkIsNotAPullRequest(_ link: String) throws {
        #expect(PullRequestLink(url: try #require(URL(string: link))) == nil)
    }

    @Test(arguments: [
        ("https://github.com/tamarinworks/porter/pull/1522", "https://github.com/tamarinworks/porter/pull/1522?via=loupe"),
        ("https://github.com/tamarinworks/porter/pull/1522/files?w=1", "https://github.com/tamarinworks/porter/pull/1522/files?w=1&via=loupe"),
        ("https://github.com/tamarinworks/porter/pull/1522#discussion_r2412345678", "https://github.com/tamarinworks/porter/pull/1522?via=loupe#discussion_r2412345678"),
        ("https://github.com/tamarinworks/porter/pull/1522/files?w=1#diff-abc", "https://github.com/tamarinworks/porter/pull/1522/files?w=1&via=loupe#diff-abc"),
        ("https://github.com/search?q=a%26b+c", "https://github.com/search?q=a%26b+c&via=loupe"),
        ("http://www.github.com/tamarinworks/porter/pull/1522", "http://www.github.com/tamarinworks/porter/pull/1522?via=loupe"),
        ("https://github.com/tamarinworks/porter/pull/1522?via=loupe", "https://github.com/tamarinworks/porter/pull/1522?via=loupe"),
    ])
    func linksToGitHubAreMarkedAsLoupesOwnForTheBrowser(_ link: String, _ marked: String) throws {
        #expect(browserURL(for: try #require(URL(string: link))).absoluteString == marked)
    }

    @Test(arguments: [
        "https://example.com/tamarinworks/porter/pull/1522?w=1#top",
        "https://gist.github.com/glenjamin/abc",
        "https://app.circleci.com/pipelines/github/tamarinworks/porter/1",
        "mailto:someone@example.com",
    ])
    func otherLinksGoToTheBrowserUnchanged(_ link: String) throws {
        let url = try #require(URL(string: link))
        #expect(browserURL(for: url) == url)
    }

    @Test func aMarkedLinkPastedBackStillOpensItsPullRequest() throws {
        let marked = browserURL(for: try #require(URL(string: "https://github.com/tamarinworks/porter/pull/1522/files#discussion_r2412345678")))
        #expect(PullRequestLink(url: marked) == PullRequestLink(repository: "tamarinworks/porter", number: 1522, target: .reviewComment(2_412_345_678)))
    }
}

/// GitHub's `#diff-` anchor for `app.go` on a PR's files, the SHA-256 of the path.
private let appGoHash = "6c4b6ed7dc8834cef100f50dae61c30ffe7775a3f3f6f5a557517cb740c44a2d"
