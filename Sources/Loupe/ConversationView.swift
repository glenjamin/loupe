import AppKit
import LoupeCore
import LoupeInbox
import LoupeModel
import SwiftUI
import WebKit

/// The Conversation tab: one web view per PR window showing the page `ConversationHTML` builds.
/// The view is kept, hidden, while the files are shown, so its scroll position survives.
struct ConversationView: NSViewRepresentable {
    let page: ConversationPage
    let conversation: Conversation?
    let error: String?
    let isShown: Bool

    func makeNSView(context: Context) -> WKWebView {
        page.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        page.show(conversation, error: error)
        let wasShown = !webView.isHidden
        webView.isHidden = !isShown
        // So the arrow keys, space and page keys scroll the conversation straight away.
        if isShown, !wasShown || webView.window?.firstResponder == nil {
            webView.window?.makeFirstResponder(webView)
        }
    }
}

/// A PR window's web view and what it last loaded. Made the first time the conversation is
/// shown and kept while the PR's tab lives.
@MainActor
final class ConversationPage: NSObject {
    let webView: WKWebView
    /// Whether the page for the latest conversation has finished loading, images included.
    private(set) var isLoaded = false
    private var shown: (conversation: Conversation?, error: String?)?

    private static let pages = NSMapTable<PullRequestTab, ConversationPage>.weakToStrongObjects()
    /// What relative links in GitHub's HTML are relative to.
    private static let baseURL = URL(string: "https://github.com/")!

    /// The tab's page, made if it hasn't one yet.
    static func page(for tab: PullRequestTab) -> ConversationPage {
        if let page = pages.object(forKey: tab) { return page }
        let page = ConversationPage()
        pages.setObject(page, forKey: tab)
        return page
    }

    /// The tab's page if the conversation has ever been shown.
    static func existingPage(for tab: PullRequestTab) -> ConversationPage? {
        pages.object(forKey: tab)
    }

    private override init() {
        let configuration = WKWebViewConfiguration()
        // Nothing the page does is kept, and it shares no cookies with anything.
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.isHidden = true
    }

    /// Loads the page for `conversation`, unless it's already showing it. Times are relative to
    /// when it's loaded, so an unchanged conversation isn't reloaded just to update them.
    func show(_ conversation: Conversation?, error: String?) {
        if let shown, shown.conversation == conversation, shown.error == error { return }
        shown = (conversation, error)
        isLoaded = false
        let html = ConversationHTML.page(conversation, error: error, template: Self.template.html, stylesheet: Self.template.css)
        webView.loadHTMLString(html, baseURL: Self.baseURL)
    }

    /// `Resources/conversation.html` and `conversation.css`, read once.
    private static let template: (html: String, css: String) = {
        guard let htmlURL = bundledResource("conversation.html", in: "Loupe_Loupe"),
              let cssURL = bundledResource("conversation.css", in: "Loupe_Loupe"),
              let html = try? String(contentsOf: htmlURL, encoding: .utf8),
              let css = try? String(contentsOf: cssURL, encoding: .utf8)
        else {
            FileHandle.standardError.write(Data("Couldn't find the conversation template; showing it unstyled\n".utf8))
            return ("<!doctype html><meta charset=utf-8><style>{{stylesheet}}</style>{{content}}", "")
        }
        return (html, css)
    }()
}

extension ConversationPage: WKNavigationDelegate, WKUIDelegate {
    /// Only the page itself loads here; links open in the default browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        let url = navigationAction.request.url
        if navigationAction.navigationType == .other, url == Self.baseURL { return .allow }
        // A link to a heading on the page itself.
        if let url, url.fragment != nil, url.absoluteString.hasPrefix(Self.baseURL.absoluteString + "#") { return .allow }
        openInBrowser(url)
        return .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
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
