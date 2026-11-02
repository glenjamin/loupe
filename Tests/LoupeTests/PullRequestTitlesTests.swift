import Foundation
import LoupeCore
import LoupeModel
import Testing
import WebKit

/// A page of GitHub's HTML gives each link to a PR its title as a tooltip.
@MainActor
struct PullRequestTitlesTests {
    @Test func linksToPullRequestsShowTheirTitlesAndOtherLinksAreLeftAlone() async throws {
        let html = #"""
            <p dir="auto">Follows <a class="issue-link js-issue-link" data-error-text="Failed to load title" data-id="1" data-permission-text="Title is private" data-url="https://github.com/tamarinworks/atrium/issues/2926" data-hovercard-type="pull_request" data-hovercard-url="/tamarinworks/atrium/pull/2926/hovercard" href="https://github.com/tamarinworks/atrium/pull/2926">#2926</a>, \#
            see <a href="https://github.com/tamarinworks/atrium/pull/2926#issuecomment-5">this comment</a> and \#
            <a href="https://github.com/tamarinworks/porter/pull/7" title="Its own">its own tooltip</a>. \#
            Fixes <a class="issue-link js-issue-link" data-hovercard-type="issue" href="https://github.com/tamarinworks/atrium/issues/12">#12</a>; \#
            nothing from <a href="https://github.com/tamarinworks/atrium/pull/404">#404</a> or <a href="https://example.com/">elsewhere</a>.</p>
            """#
        let view = try await loadedPage(html)
        var asked: [PullRequestLink] = []

        await PullRequestTitles.add(to: view) { links in
            asked = links
            return Dictionary(uniqueKeysWithValues: links.filter { $0.number == 2926 }.map { ($0, "Bump gazette") })
        }

        #expect(Set(asked.map { "\($0.repository)#\($0.number)" }) == ["tamarinworks/atrium#2926", "tamarinworks/atrium#404"])
        let script = "return [...document.querySelectorAll('a')].map(a => a.textContent + ': ' + a.title)"
        let titles = try await view.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String]
        #expect(titles == ["#2926: Bump gazette", "this comment: Bump gazette", "its own tooltip: Its own", "#12: ", "#404: ", "elsewhere: "])
    }
}
