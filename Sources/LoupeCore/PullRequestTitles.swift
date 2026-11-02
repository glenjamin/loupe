import Foundation
import LoupeModel
import WebKit

/// Each link to a PR on a page of GitHub's HTML shows the PR's title when the pointer rests on
/// it, standing in for github.com's hovercards, which the page can't show.
@MainActor
public enum PullRequestTitles {
    /// Gives the loaded page's links to PRs their titles, as `lookUp` finds them for every PR
    /// linked. A link with a tooltip of its own keeps it.
    public static func add(to webView: WKWebView, lookingUp lookUp: ([PullRequestLink]) async -> [PullRequestLink: String]) async {
        guard let hrefs = try? await webView.callAsyncJavaScript(linksScript, arguments: [:], in: nil, contentWorld: .defaultClient) as? [String] else { return }
        let links = hrefs.compactMap { href in
            URL(string: href).flatMap(PullRequestLink.init(url:)).map { (href: href, link: $0) }
        }
        guard !links.isEmpty else { return }
        let found = await lookUp(links.map(\.link))
        let titles = Dictionary(links.compactMap { link in found[link.link].map { (link.href, $0) } }) { first, _ in first }
        guard !titles.isEmpty else { return }
        _ = try? await webView.callAsyncJavaScript(titlesScript, arguments: ["titles": titles], in: nil, contentWorld: .defaultClient)
    }

    /// Every web link on the page without a tooltip, once each.
    private static let linksScript = """
        const untitled = [...document.querySelectorAll('a[href]:not([title])')].filter(a => /^https?:/.test(a.href));
        return [...new Set(untitled.map(a => a.href))];
        """

    private static let titlesScript = """
        for (const a of document.querySelectorAll('a[href]:not([title])')) {
          if (Object.hasOwn(titles, a.href)) a.title = titles[a.href];
        }
        """
}
