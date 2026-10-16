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
        #expect(found == PullRequestLink(repository: "tamarinworks/porter", number: 1522))
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
        #expect(PullRequestLink(url: marked) == PullRequestLink(repository: "tamarinworks/porter", number: 1522))
    }
}
