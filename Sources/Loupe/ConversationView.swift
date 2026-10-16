import AppKit
import LoupeCore
import LoupeInbox
import LoupeModel
import SwiftUI
import WebKit

/// The Conversation tab: one web view per PR window showing the page `ConversationHTML` builds.
/// The view is kept, hidden, while the files are shown, so its scroll position survives. A
/// thread the page asks to show that the diff can't is said so over it. A thread's reply is
/// written in a popover by the thread, or in a sheet if the page has lost sight of it. A
/// comment on the PR is written in a popover by the page's "Add a comment…".
struct ConversationView: View {
    let page: ConversationPage
    let conversation: Conversation?
    let error: String?
    let isShown: Bool
    /// The thread whose reply couldn't be put by it, so is written in a sheet.
    @State private var replyingInSheet: String?

    var body: some View {
        ConversationWebView(page: page, conversation: conversation, error: error, isShown: isShown)
            .overlay(alignment: .bottom) {
                if isShown, let tab = page.tab, let unshown = tab.threadActivity.unshown {
                    UnshownThreadNote(tab: tab, unshown: unshown)
                }
            }
            .task(id: replying) {
                guard let replying else {
                    page.closeReply()
                    replyingInSheet = nil
                    return
                }
                if await !page.showReply(to: replying) { replyingInSheet = replying }
            }
            .sheet(isPresented: isReplyingInSheet) {
                if let tab = page.tab, let replyingInSheet {
                    ConversationReply(tab: tab, threadId: replyingInSheet)
                }
            }
            .task(id: isCommenting) {
                guard isCommenting else { return page.closeComment() }
                // Only a page still loading has no link to put it by; it's put away, keeping
                // the draft, for "Add a comment…" to open again.
                if await !page.showComment() { page.tab?.conversationComment.close() }
            }
    }

    /// Whether a comment on the PR is being written over the page while it's shown, until it's
    /// sent, dropped or put away.
    private var isCommenting: Bool {
        guard isShown, let comment = page.tab?.conversationComment else { return false }
        return comment.isOpen && comment.draft != nil
    }

    /// The thread being replied to over the page while it's shown, until the reply is sent,
    /// dropped or put away.
    private var replying: String? {
        guard isShown, let activity = page.tab?.threadActivity, let id = activity.replyingInConversation, activity.replies[id] != nil else { return nil }
        return id
    }

    private var isReplyingInSheet: Binding<Bool> {
        Binding {
            replyingInSheet != nil && replyingInSheet == replying
        } set: { isPresented in
            guard !isPresented else { return }
            replyingInSheet = nil
            page.tab?.threadActivity.closeConversationReply()
        }
    }
}

private struct ConversationWebView: NSViewRepresentable {
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
    /// The tab the page shows the conversation of.
    private(set) weak var tab: PullRequestTab?
    /// The open reply's popover, and the thread it's to.
    private(set) var replyPopover: (threadId: String, popover: NSPopover)?
    /// The open comment on the PR's popover.
    private(set) var commentPopover: NSPopover?

    private static let pages = NSMapTable<PullRequestTab, ConversationPage>.weakToStrongObjects()

    /// The tab's page, made if it hasn't one yet.
    static func page(for tab: PullRequestTab) -> ConversationPage {
        if let page = pages.object(forKey: tab) { return page }
        let page = ConversationPage()
        page.tab = tab
        page.openPullRequestLink = { [weak tab] in await tab?.open($0) ?? false }
        page.openThreadLink = { [weak tab] link in Task { await tab?.follow(link) } }
        page.openReactionLink = { [weak tab] link in Task { await tab?.react(link) } }
        page.openCommentLink = { [weak tab] link in tab?.follow(link) }
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

    /// Shows the reply to the thread in a popover by it, unless the page has no such thread in
    /// view to put it by, as when it's scrolled away meanwhile; returns whether it could.
    func showReply(to threadId: String) async -> Bool {
        if let replyPopover, replyPopover.threadId == threadId, replyPopover.popover.isShown { return true }
        closeReply()
        guard let tab, let rect = await rectOfThread(threadId) else { return false }
        let hosting = NSHostingController(rootView: ConversationReply(tab: tab, threadId: threadId))
        hosting.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        // A click elsewhere puts it away, as Esc does, keeping the draft.
        popover.behavior = .transient
        popover.contentViewController = hosting
        popover.delegate = self
        popover.show(relativeTo: rect, of: webView, preferredEdge: .minY)
        replyPopover = (threadId, popover)
        return true
    }

    /// Closes the reply's popover, if it's open, leaving the reply as it is.
    func closeReply() {
        guard let replyPopover else { return }
        self.replyPopover = nil
        // Closed for the reply's sake, so it's not taken as the reader putting the reply away.
        replyPopover.popover.delegate = nil
        replyPopover.popover.close()
    }

    /// Shows the comment on the PR in a popover by "Add a comment…", scrolling it into view if
    /// it isn't, unless the page has no such link yet; returns whether it could.
    func showComment() async -> Bool {
        if let commentPopover, commentPopover.isShown { return true }
        closeComment()
        guard let tab, let rect = await rectOfCommentLink() else { return false }
        let hosting = NSHostingController(rootView: ConversationCommentView(tab: tab))
        hosting.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        // A click elsewhere puts it away, as Esc does, keeping the draft.
        popover.behavior = .transient
        popover.contentViewController = hosting
        popover.delegate = self
        popover.show(relativeTo: rect, of: webView, preferredEdge: .minY)
        commentPopover = popover
        return true
    }

    /// Closes the comment's popover, if it's open, leaving the comment as it is.
    func closeComment() {
        guard let commentPopover else { return }
        self.commentPopover = nil
        // Closed for the comment's sake, so it's not taken as the reader putting it away.
        commentPopover.delegate = nil
        commentPopover.close()
    }

    /// Where "Add a comment…" sits in the web view, scrolled into view if need be; nil if the
    /// page has none.
    private func rectOfCommentLink() async -> NSRect? {
        let script = """
            const link = document.querySelector('[data-new-comment]');
            if (!link) return null;
            link.scrollIntoView({ block: 'nearest' });
            const rect = link.getBoundingClientRect();
            return [rect.left, rect.top, rect.width, rect.height];
            """
        let found = try? await webView.callAsyncJavaScript(script, arguments: [:], in: nil, contentWorld: .defaultClient)
        guard let values = found as? [Double], values.count == 4 else { return nil }
        return viewRect(left: values[0], top: values[1], width: values[2], height: values[3])
    }

    /// Where an open thread's actions sit at its foot, or the thread itself when it's folded or
    /// has none, in the web view, kept to what's in view; nil if none of it is.
    private func rectOfThread(_ threadId: String) async -> NSRect? {
        let script = """
            const thread = document.querySelector(`details[data-thread-id="${CSS.escape(id)}"]`);
            if (!thread) return null;
            const actions = thread.open ? thread.querySelector(':scope > .thread-actions') : null;
            const rect = (actions ?? thread).getBoundingClientRect();
            const top = Math.max(rect.top, 0), bottom = Math.min(rect.bottom, window.innerHeight);
            return bottom > top ? [rect.left, top, rect.width, bottom - top] : null;
            """
        let found = try? await webView.callAsyncJavaScript(script, arguments: ["id": threadId], in: nil, contentWorld: .defaultClient)
        guard let values = found as? [Double], values.count == 4 else { return nil }
        return viewRect(left: values[0], top: values[1], width: values[2], height: values[3])
    }

    /// A rect in the page's viewport, from its top left, in the web view's coordinates.
    private func viewRect(left: Double, top: Double, width: Double, height: Double) -> NSRect {
        NSRect(x: left, y: webView.isFlipped ? top : webView.bounds.height - top - height, width: width, height: height)
    }

    private static let baseURL = URL(string: "https://github.com/")!
}

extension ConversationPage: NSPopoverDelegate {
    /// A popover closed by Esc or a click elsewhere puts the reply or comment away, its draft kept.
    func popoverDidClose(_ notification: Notification) {
        if let commentPopover, notification.object as? NSPopover === commentPopover {
            self.commentPopover = nil
            tab?.conversationComment.close()
            return
        }
        guard let replyPopover else { return }
        self.replyPopover = nil
        if tab?.threadActivity.replyingInConversation == replyPopover.threadId { tab?.threadActivity.closeConversationReply() }
    }
}
