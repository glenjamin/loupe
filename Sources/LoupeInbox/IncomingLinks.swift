import Foundation
import LoupeModel

/// Links handed to the app from outside, such as one clicked in Slack or mail and routed here,
/// or `open -a Loupe <url>`. A link to a PR opens its tab; any other web link goes to the
/// browser. Links that arrive before the tabs exist, as at launch, wait for them.
@MainActor
public final class IncomingLinks {
    /// Brings the window to the front, as a PR link is about to be shown in it.
    private let bringForward: @MainActor () -> Void
    private let openInBrowser: @MainActor (URL) -> Void
    private var tabs: TabsModel?
    private var waiting: [URL] = []

    public init(bringForward: @escaping @MainActor () -> Void, openInBrowser: @escaping @MainActor (URL) -> Void) {
        self.bringForward = bringForward
        self.openInBrowser = openInBrowser
    }

    /// Opens each link in turn, or keeps them until `ready` if the tabs aren't there yet.
    public func open(_ urls: [URL]) async {
        guard let tabs else {
            waiting += urls
            return
        }
        for url in urls { await open(url, in: tabs) }
    }

    /// The tabs can now show PRs; opens the links that arrived before them.
    public func ready(_ tabs: TabsModel) async {
        self.tabs = tabs
        let urls = waiting
        waiting = []
        await open(urls)
    }

    private func open(_ url: URL, in tabs: TabsModel) async {
        if let link = PullRequestLink(url: url) {
            bringForward()
            // A PR GitHub won't show us still opens somewhere, so the click isn't lost.
            if await !tabs.open(link), let web = webURL(url) { openInBrowser(web) }
        } else if ["http", "https"].contains(url.scheme?.lowercased()) {
            openInBrowser(url)
        } else {
            log("Ignoring a link Loupe can't open: \(url.absoluteString)")
        }
    }
}

/// The page on github.com a PR link names: itself for http and https, and for Loupe's own
/// scheme the same path there.
private func webURL(_ url: URL) -> URL? {
    guard url.scheme?.lowercased() == "loupe" else { return url }
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
    components.scheme = "https"
    if components.host?.isEmpty ?? true { components.host = "github.com" }
    return components.url
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
