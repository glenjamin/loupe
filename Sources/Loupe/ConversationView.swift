import AppKit
import LoupeCore
import LoupeInbox
import LoupeModel
import SwiftUI
import WebKit

/// The Conversation tab: one web view per PR window showing the page `ConversationHTML` builds.
/// The view is kept, hidden, while the files are shown, so its scroll position survives. Until
/// a conversation's page has loaded, a native wait or failure covers it, as the diff's does. A
/// thread the page asks to show that the diff can't is said so over it. A thread's reply is
/// written in a popover by the thread, or in a sheet if the page has lost sight of it. A
/// comment on the PR is written in a popover by the page's "Add a comment…", and an edit of the
/// viewer's comment or review in one by its "Edit"; its "Delete" asks first, in an alert.
struct ConversationView: View {
    let page: ConversationPage
    let pullRequest: PullRequestSummary
    let conversation: Conversation?
    /// Why the conversation couldn't be fetched, nil while it's being fetched again.
    let error: String?
    let isShown: Bool
    /// The thread whose reply couldn't be put by it, so is written in a sheet.
    @State private var replyingInSheet: String?

    var body: some View {
        ConversationWebView(page: page, conversation: conversation, isShown: isShown)
            .overlay {
                // Opaque, so the web view is never seen blank or half drawn before its first page.
                if isShown, !page.hasLoadedConversation {
                    placeholder
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color(nsColor: .windowBackgroundColor))
                }
            }
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
            .task(id: editing) {
                guard let editing else { return page.closeEdit() }
                // A page with no such "Edit" in it to put it by puts it away, keeping the edit,
                // for the link to open again.
                if await !page.showEdit(of: editing) { page.tab?.commentEdits.closeConversationEdit() }
            }
            .alert("Delete this comment?", isPresented: isConfirmingDeletion) {
                Button("Delete", role: .destructive) {
                    // Taken now, as closing the alert forgets which comment it asked about.
                    guard let tab = page.tab, let id = tab.commentEdits.confirmingDeletion else { return }
                    Task { await tab.deleteFromConversation(id) }
                }
                Button("Keep", role: .cancel) { page.tab?.commentEdits.keepComment() }
            } message: {
                Text("It'll be gone from GitHub for everyone.")
            }
            .alert(Text(verbatim: page.tab?.commentEdits.deletionError ?? ""), isPresented: hasDeletionError) {
                Button("OK", role: .cancel) { page.tab?.commentEdits.dismissDeletionError() }
            }
    }

    /// Whether a "Delete" in the page is being confirmed while it's shown.
    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { isShown && page.tab?.commentEdits.confirmingDeletion != nil },
            set: { if !$0 { page.tab?.commentEdits.keepComment() } }
        )
    }

    /// Whether GitHub's refusal of a deletion asked for in the page is to be shown.
    private var hasDeletionError: Binding<Bool> {
        Binding(
            get: { isShown && page.tab?.commentEdits.deletionError != nil },
            set: { if !$0 { page.tab?.commentEdits.dismissDeletionError() } }
        )
    }

    /// What's being edited over the page while it's shown, until it's saved, dropped or put
    /// away.
    private var editing: String? {
        guard isShown, let edits = page.tab?.commentEdits, let id = edits.editingInConversation, edits.edits[id] != nil else { return nil }
        return id
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

    /// The wait for the conversation, laid out as the diff's, or why it couldn't be fetched
    /// when there's none stored to show instead.
    @ViewBuilder
    private var placeholder: some View {
        if conversation == nil, let error {
            ContentUnavailableView {
                Label("Couldn't load the conversation", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error).textSelection(.enabled)
            } actions: {
                Button("Try Again") { Task { await page.tab?.retryConversation() } }
            }
        } else {
            LoadingLabel(title: "Fetching the conversation…", detail: "\(pullRequest.repository) #\(pullRequest.number)")
        }
    }
}

private struct ConversationWebView: NSViewRepresentable {
    let page: ConversationPage
    let conversation: Conversation?
    let isShown: Bool

    func makeNSView(context: Context) -> WKWebView {
        page.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        if let conversation { page.show(conversation) }
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
@Observable
final class ConversationPage: GitHubWebPage {
    /// Whether a conversation's page has finished loading, so the web view can be seen. Once it
    /// has, a page replacing it shows over it as WebKit draws it, keeping the reader's place.
    private(set) var hasLoadedConversation = false
    @ObservationIgnored private var shown: Conversation?
    /// Where the reader had scrolled to on the page being replaced, to put them back there.
    @ObservationIgnored private var restoredOffset: Double?
    /// A picture of the page being replaced, over the web view until its replacement is ready.
    @ObservationIgnored private var coverView: NSImageView?
    /// Counts the pages asked for, so only the latest is loaded.
    @ObservationIgnored private var requested = 0
    /// The tab the page shows the conversation of.
    @ObservationIgnored private(set) weak var tab: PullRequestTab?
    /// The open reply's popover, and the thread it's to.
    @ObservationIgnored private(set) var replyPopover: (threadId: String, popover: NSPopover)?
    /// The open comment on the PR's popover.
    @ObservationIgnored private(set) var commentPopover: NSPopover?
    /// The open edit's popover, and the id of what it edits.
    @ObservationIgnored private(set) var editPopover: (commentId: String, popover: NSPopover)?

    private static let pages = NSMapTable<PullRequestTab, ConversationPage>.weakToStrongObjects()

    /// The tab's page, made if it hasn't one yet.
    static func page(for tab: PullRequestTab) -> ConversationPage {
        if let page = pages.object(forKey: tab) { return page }
        let page = ConversationPage()
        page.tab = tab
        page.openPullRequestLink = { [weak tab] in await tab?.open($0) ?? false }
        page.openThreadLink = { [weak tab] link in Task { await tab?.follow(link) } }
        page.openReactionLink = { [weak tab] link in Task { await tab?.react(link) } }
        page.openCommentLink = { [weak tab] link in Task { await tab?.follow(link) } }
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
    /// to update them. A page replacing one is covered by a picture of the old until it's ready.
    func show(_ conversation: Conversation) {
        if shown == conversation { return }
        let isReplacing = shown != nil
        shown = conversation
        requested += 1
        let request = requested
        let html = ConversationHTML.page(conversation, template: Self.template.html, stylesheet: Self.template.css)
        // A page still loading has no place of its own yet; the one it replaced is kept for it.
        guard isReplacing, isLoaded else { return load(html, baseURL: Self.baseURL) }
        Task {
            // In the app's own script world, as the page's policy allows no script of its own.
            let offset = try? await webView.evaluateJavaScript("window.scrollY", in: nil, contentWorld: .defaultClient)
            guard request == requested else { return }
            restoredOffset = offset as? Double
            await cover()
            guard request == requested else { return }
            load(html, baseURL: Self.baseURL)
        }
    }

    /// Shows the page once it's been put back where the reader was and drawn there, so neither
    /// its top nor images still arriving are seen first.
    override func didFinishLoading() {
        let offset = restoredOffset ?? -1
        restoredOffset = nil
        let request = requested
        Task {
            _ = try? await webView.callAsyncJavaScript(Self.settleScript, arguments: ["offset": offset], in: nil, contentWorld: .defaultClient)
            // A newer page on its way uncovers itself once it's ready.
            guard request == requested, isLoaded else { return }
            hasLoadedConversation = true
            coverView?.removeFromSuperview()
            coverView = nil
        }
    }

    /// Puts a picture of the page as it is over the web view, unless it's already covered or
    /// can't be seen anyway.
    private func cover() async {
        guard coverView == nil, !webView.isHidden, let image = try? await webView.takeSnapshot(configuration: nil) else { return }
        let cover = NSImageView(image: image)
        cover.imageScaling = .scaleAxesIndependently
        cover.frame = webView.bounds
        cover.autoresizingMask = [.width, .height]
        webView.addSubview(cover)
        coverView = cover
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

    /// Shows the edit of the comment or review with `commentId` in a popover by its "Edit",
    /// scrolling that into view if it isn't, unless the page has none; returns whether it could.
    func showEdit(of commentId: String) async -> Bool {
        if let editPopover, editPopover.commentId == commentId, editPopover.popover.isShown { return true }
        closeEdit()
        guard let tab, let rect = await rectOfEditLink(commentId) else { return false }
        let hosting = NSHostingController(rootView: ConversationEditView(tab: tab, commentId: commentId))
        hosting.sizingOptions = .preferredContentSize
        let popover = NSPopover()
        // A click elsewhere puts it away, as Esc does, keeping the edit.
        popover.behavior = .transient
        popover.contentViewController = hosting
        popover.delegate = self
        popover.show(relativeTo: rect, of: webView, preferredEdge: .minY)
        editPopover = (commentId, popover)
        return true
    }

    /// Closes the edit's popover, if it's open, leaving the edit as it is.
    func closeEdit() {
        guard let editPopover else { return }
        self.editPopover = nil
        // Closed for the edit's sake, so it's not taken as the reader putting it away.
        editPopover.popover.delegate = nil
        editPopover.popover.close()
    }

    /// Quotes what's selected in one comment of the page into a reply, as github.com's `r` does:
    /// a thread's comment into the thread's reply, any other into the comment on the PR. Returns
    /// whether there was such a selection.
    @discardableResult
    func quoteSelection() async -> Bool {
        guard let tab, let found = try? await webView.evaluateJavaScript(Self.selectionScript, in: nil, contentWorld: .defaultClient),
              let selection = found as? [String: Any], let html = selection["html"] as? String else { return false }
        let markdown = QuoteReply.markdown(fromHTML: html)
        guard !markdown.isEmpty else { return false }
        tab.quoteInConversation(markdown, fromThread: selection["thread"] as? String)
        return true
    }

    /// Where "Add a comment…" sits in the web view, scrolled into view if need be; nil if the
    /// page has none.
    private func rectOfCommentLink() async -> NSRect? {
        await rectOfLink("[data-new-comment]")
    }

    /// Where the "Edit" of the comment or review with `commentId` sits in the web view, scrolled
    /// into view if need be; nil if the page has none.
    private func rectOfEditLink(_ commentId: String) async -> NSRect? {
        await rectOfLink(#"[data-edit-comment="${CSS.escape(id)}"]"#, id: commentId)
    }

    /// Where the first element matching `selector` sits in the web view, scrolled into view if
    /// need be; `${CSS.escape(id)}` in the selector is filled from `id`.
    private func rectOfLink(_ selector: String, id: String = "") async -> NSRect? {
        let script = """
            const link = document.querySelector(`\(selector)`);
            if (!link) return null;
            link.scrollIntoView({ block: 'nearest' });
            const rect = link.getBoundingClientRect();
            return [rect.left, rect.top, rect.width, rect.height];
            """
        let found = try? await webView.callAsyncJavaScript(script, arguments: ["id": id], in: nil, contentWorld: .defaultClient)
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

    /// The selection's HTML, inside clones of the elements it's within up to its comment's body
    /// so a part of a code block or link stays one, and the id of the thread that comment is in;
    /// null unless the selection is within a single comment's body. A thread's own comments
    /// have their own body inside a review's, so the review's counts only outside its threads.
    private static let selectionScript = """
        (() => {
          const selection = window.getSelection();
          if (!selection || selection.isCollapsed || selection.rangeCount === 0) return null;
          const range = selection.getRangeAt(0);
          const element = node => node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
          const bodyOf = node => {
            const body = element(node)?.closest('.body');
            const thread = element(node)?.closest('details.thread');
            return body && (!thread || thread.contains(body)) ? body : null;
          };
          const body = bodyOf(range.startContainer);
          if (!body || body !== bodyOf(range.endContainer)) return null;
          let selected = range.cloneContents();
          for (let inside = element(range.commonAncestorContainer); inside && inside !== body; inside = inside.parentElement) {
            const clone = inside.cloneNode(false);
            clone.appendChild(selected);
            selected = clone;
          }
          const holder = document.createElement('div');
          holder.appendChild(selected);
          holder.querySelectorAll('.reactions, details.thread, details.minimized > summary').forEach(hidden => hidden.remove());
          return { html: holder.innerHTML, thread: body.closest('details.thread')?.dataset.threadId ?? null };
        })()
        """

    /// Scrolls to `offset` unless it's negative, then waits for a frame to be drawn, or a moment
    /// where frames are held back, as in a window off screen.
    private static let settleScript = """
        if (offset >= 0) window.scrollTo(0, offset);
        await Promise.race([
          new Promise(done => requestAnimationFrame(() => requestAnimationFrame(done))),
          new Promise(done => setTimeout(done, 250)),
        ]);
        """
}

extension ConversationPage: NSPopoverDelegate {
    /// A popover closed by Esc or a click elsewhere puts the reply, comment or edit away, its
    /// draft kept.
    func popoverDidClose(_ notification: Notification) {
        if let commentPopover, notification.object as? NSPopover === commentPopover {
            self.commentPopover = nil
            tab?.conversationComment.close()
            return
        }
        if let editPopover, notification.object as? NSPopover === editPopover.popover {
            self.editPopover = nil
            if tab?.commentEdits.editingInConversation == editPopover.commentId { tab?.commentEdits.closeConversationEdit() }
            return
        }
        guard let replyPopover else { return }
        self.replyPopover = nil
        if tab?.threadActivity.replyingInConversation == replyPopover.threadId { tab?.threadActivity.closeConversationReply() }
    }
}
