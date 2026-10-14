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

/// A PR window's conversation web view and what it last loaded. Made the first time the
/// conversation is shown and kept while the PR's tab lives.
@MainActor
final class ConversationPage: GitHubWebPage {
    private var shown: (conversation: Conversation?, error: String?)?

    private static let pages = NSMapTable<PullRequestTab, ConversationPage>.weakToStrongObjects()

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
        super.init()
        webView.isHidden = true
    }

    /// Loads the page for `conversation`, unless it's already showing it. Times are relative to
    /// when it's loaded, so an unchanged conversation isn't reloaded just to update them.
    func show(_ conversation: Conversation?, error: String?) {
        if let shown, shown.conversation == conversation, shown.error == error { return }
        shown = (conversation, error)
        let html = ConversationHTML.page(conversation, error: error, template: Self.template.html, stylesheet: Self.template.css)
        load(html, baseURL: URL(string: "https://github.com/")!)
    }
}
