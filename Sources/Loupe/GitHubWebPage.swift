import AppKit
import LoupeCore
import LoupeModel
import WebKit

/// A web view showing a page we assemble around GitHub's rendered HTML, from
/// `Resources/conversation.html` and `conversation.css`. It loads only that page, keeps nothing
/// and shares no cookies. Links to PRs go to `openPullRequestLink`, those to its review threads
/// to `openThreadLink`, and other links to the default browser.
@MainActor
class GitHubWebPage: NSObject {
    let webView: WKWebView
    /// Opens a linked PR in the app, returning whether it could; set by whoever makes the page.
    var openPullRequestLink: @MainActor (PullRequestLink) async -> Bool = { _ in false }
    /// Acts on a link to one of the page's review threads; set by whoever makes the page.
    var openThreadLink: @MainActor (ThreadLink) -> Void = { _ in }
    /// Adds or takes away the viewer's reaction a link names; set by whoever makes the page.
    var openReactionLink: @MainActor (ReactionLink) -> Void = { _ in }
    /// Whether the latest page has finished loading, images included.
    private(set) var isLoaded = false
    /// What relative links in the page are relative to.
    private var baseURL = URL(string: "https://github.com/")!

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        // GitHub's light theme whatever the system appearance: WebKit takes the page's
        // `prefers-color-scheme` from the view's appearance, and GitHub's HTML has dark variants.
        webView.appearance = NSAppearance(named: .aqua)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func load(_ html: String, baseURL: URL) {
        isLoaded = false
        self.baseURL = baseURL
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    /// Called once the latest page has loaded.
    func didFinishLoading() {}

    /// `Resources/conversation.html` and `conversation.css`, read once.
    static let template: (html: String, css: String) = {
        guard let htmlURL = bundledResource("conversation.html", in: "Loupe_Loupe"),
              let cssURL = bundledResource("conversation.css", in: "Loupe_Loupe"),
              let html = try? String(contentsOf: htmlURL, encoding: .utf8),
              let css = try? String(contentsOf: cssURL, encoding: .utf8)
        else {
            FileHandle.standardError.write(Data("Couldn't find the page template; showing it unstyled\n".utf8))
            return ("<!doctype html><meta charset=utf-8><style>{{stylesheet}}</style><main class=\"{{layout}}\">{{content}}</main>", "")
        }
        return (html, css)
    }()
}

extension GitHubWebPage: WKNavigationDelegate, WKUIDelegate {
    /// Only the page itself loads here; links are followed elsewhere.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        if navigationAction.navigationType == .other, url == baseURL { return .allow }
        // A link to a heading on the page itself.
        if let url, url.fragment != nil, url.absoluteString.hasPrefix(baseURL.absoluteString + "#") { return .allow }
        follow(navigationAction)
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        didFinishLoading()
    }

    /// A link that asks for a new window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        follow(navigationAction)
        return nil
    }

    /// ⌘-click and the middle button ask for a new browser tab, so they go to the browser even
    /// for a PR. A thread's links act in the app however they're clicked, as no browser could.
    private func follow(_ action: WKNavigationAction) {
        if let url = action.request.url, let link = ThreadLink(url: url) { return openThreadLink(link) }
        if let url = action.request.url, let link = ReactionLink(url: url) { return openReactionLink(link) }
        let inBrowserTab = action.modifierFlags.contains(.command) || action.buttonNumber == middleMouseButton
        followLink(action.request.url, inBrowserTab: inBrowserTab, openPullRequest: openPullRequestLink)
    }
}

/// Opens a link to a PR in the app, unless asked for a browser tab or the app can't, and any
/// other web or mail link in the default browser.
@MainActor
func followLink(_ url: URL?, inBrowserTab: Bool, openPullRequest: @escaping @MainActor (PullRequestLink) async -> Bool) {
    guard let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
    guard !inBrowserTab, let link = PullRequestLink(url: url) else {
        openInBrowser(url)
        return
    }
    Task {
        if await !openPullRequest(link) { openInBrowser(url) }
    }
}

/// AppKit's number for the middle mouse button, as `WKNavigationAction.buttonNumber` reports it.
private let middleMouseButton = 2
