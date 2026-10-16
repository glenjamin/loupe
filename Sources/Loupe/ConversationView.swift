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
    /// Where the reader had scrolled to on the page being replaced, to put them back there.
    private var restoredOffset: Double?
    /// Counts the pages asked for, so only the latest is loaded.
    private var requested = 0

    private static let pages = NSMapTable<PullRequestTab, ConversationPage>.weakToStrongObjects()

    /// The tab's page, made if it hasn't one yet.
    static func page(for tab: PullRequestTab) -> ConversationPage {
        if let page = pages.object(forKey: tab) { return page }
        let page = ConversationPage()
        page.openPullRequestLink = { [weak tab] in await tab?.open($0) ?? false }
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

    /// Loads the page for `conversation`, unless it's already showing it, keeping the reader's
    /// place when it replaces one, as it does when the conversation updates in the background.
    /// Times are relative to when it's loaded, so an unchanged conversation isn't reloaded just
    /// to update them.
    func show(_ conversation: Conversation?, error: String?) {
        if let shown, shown.conversation == conversation, shown.error == error { return }
        let isReplacing = shown != nil
        shown = (conversation, error)
        requested += 1
        let request = requested
        let html = ConversationHTML.page(conversation, error: error, template: Self.template.html, stylesheet: Self.template.css)
        // A page still loading has no place of its own yet; the one it replaced is kept for it.
        guard isReplacing, isLoaded else { return load(html, baseURL: Self.baseURL) }
        Task {
            // In the app's own script world, as the page's policy allows no script of its own.
            let offset = try? await webView.evaluateJavaScript("window.scrollY", in: nil, contentWorld: .defaultClient)
            guard request == requested else { return }
            restoredOffset = offset as? Double
            load(html, baseURL: Self.baseURL)
        }
    }

    override func didFinishLoading() {
        guard let offset = restoredOffset else { return }
        restoredOffset = nil
        webView.evaluateJavaScript("window.scrollTo(0, \(offset))", in: nil, in: .defaultClient)
    }

    private static let baseURL = URL(string: "https://github.com/")!
}
