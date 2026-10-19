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

    /// Opens each link, or keeps them until `ready` if the tabs aren't there yet. Every PR's tab
    /// shows at once, in the order the links came; returns once any looked up have been found
    /// or failed.
    public func open(_ urls: [URL]) async {
        guard let tabs else {
            waiting += urls
            return
        }
        let lookups = urls.compactMap { open($0, in: tabs) }
        for lookup in lookups { await lookup.value }
    }

    /// The tabs can now show PRs; opens the links that arrived before them.
    public func ready(_ tabs: TabsModel) async {
        self.tabs = tabs
        let urls = waiting
        waiting = []
        await open(urls)
    }

    private func open(_ url: URL, in tabs: TabsModel) -> Task<Void, Never>? {
        if let link = PullRequestLink(url: url) {
            bringForward()
            return tabs.open(link)
        } else if ["http", "https"].contains(url.scheme?.lowercased()) {
            openInBrowser(url)
        } else {
            log("Ignoring a link Loupe can't open: \(url.absoluteString)")
        }
        return nil
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
