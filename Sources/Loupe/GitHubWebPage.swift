import AppKit
import LoupeCore
import WebKit

/// A web view showing a page we assemble around GitHub's rendered HTML, from
/// `Resources/conversation.html` and `conversation.css`. It loads only that page, keeps nothing
/// and shares no cookies, and opens links in the default browser.
@MainActor
class GitHubWebPage: NSObject {
    let webView: WKWebView
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
    /// Only the page itself loads here; links open in the default browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        if navigationAction.navigationType == .other, url == baseURL { return .allow }
        // A link to a heading on the page itself.
        if let url, url.fragment != nil, url.absoluteString.hasPrefix(baseURL.absoluteString + "#") { return .allow }
        openInBrowser(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        didFinishLoading()
    }

    /// A link that asks for a new window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        openInBrowser(navigationAction.request.url)
        return nil
    }

    private func openInBrowser(_ url: URL?) {
        guard let url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") else { return }
        NSWorkspace.shared.open(url)
    }
}
