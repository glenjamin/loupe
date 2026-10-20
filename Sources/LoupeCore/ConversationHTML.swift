import Foundation
import LoupeModel

/// A PR's conversation as one HTML page, from a template with `{{stylesheet}}`, `{{layout}}` and
/// `{{content}}` in it. GitHub's `bodyHTML` fragments go in verbatim, as GitHub has already rendered and
/// sanitised them; every other string is escaped.
public enum ConversationHTML {
    /// The page for `conversation`. Waiting for one, or failing to get one, is shown natively.
    public static func page(_ conversation: Conversation, template: String, stylesheet: String, now: Date = .now) -> String {
        fill(template, layout: "timeline", content: render(conversation, now: now), stylesheet: stylesheet)
    }

    /// The template with its placeholders filled, `layout` being the class of its `main`.
    static func fill(_ template: String, layout: String, content: String, stylesheet: String) -> String {
        // The stylesheet goes in first, so a `{{content}}` inside it can't be replaced.
        template
            .replacingOccurrences(of: "{{layout}}", with: layout)
            .replacingOccurrences(of: "{{content}}", with: content)
            .replacingOccurrences(of: "{{stylesheet}}", with: stylesheet)
    }

    private static func render(_ conversation: Conversation, now: Date) -> String {
        let threads = Dictionary(conversation.threads.flatMap { thread in thread.comments.map { ($0.id, thread) } }, uniquingKeysWith: { first, _ in first })
        var html = card(
            author: conversation.author,
            action: "opened this pull request",
            date: conversation.createdAt,
            now: now,
            body: conversation.bodyHTML.isEmpty ? #"<p class="muted">No description provided.</p>"# : conversation.bodyHTML,
            reactions: reactions(conversation.reactions, to: conversation.id)
        )
        var commits: [TimelineItem] = []
        func flushCommits() {
            guard !commits.isEmpty else { return }
            html += commitList(commits)
            commits = []
        }
        for item in conversation.items {
            if case .commit = item.event {
                commits.append(item)
                continue
            }
            flushCommits()
            html += render(item, threads: threads, now: now)
        }
        flushCommits()
        html += checks(conversation.checks)
        html += newComment
        return html
    }

    private static func render(_ item: TimelineItem, threads: [String: ReviewThread], now: Date) -> String {
        switch item.event {
        case let .comment(bodyHTML, isMinimized):
            // One on its way to GitHub can't be reacted to until GitHub has it.
            let reactions = item.isSending ? "" : reactions(item.reactions, to: item.id)
            let isSettled = !item.isSending && !item.isSaving
            let edit = commentActions(item.id, canEdit: item.viewerCanUpdate && isSettled, canDelete: item.viewerCanDelete && isSettled)
            return card(
                author: item.actor, action: "commented", date: item.date, now: now, isSending: item.isSending, isSaving: item.isSaving, edit: edit,
                body: minimizable(bodyHTML, isMinimized: isMinimized), reactions: reactions
            )
        case let .review(state, bodyHTML, comments):
            // Replies are shown in their threads, under the review that started them.
            let started = comments.filter { $0.replyTo == nil }
            if bodyHTML.isEmpty, started.isEmpty, state == .commented { return "" }
            // A review's own reactions are to its summary, so they go under it, before its threads;
            // the viewer's pending review takes none until it's submitted, nor one on its way.
            let summaryReactions = bodyHTML.isEmpty || state == .pending || item.isSending ? "" : reactions(item.reactions, to: item.id)
            let body = (bodyHTML.isEmpty ? "" : bodyHTML + summaryReactions) + started.map { thread(for: $0, in: threads[$0.id], reviewer: item.actor, date: item.date, now: now) }.joined()
            // Only a submitted summary is edited here; a pending one is written in "Finish your review".
            let edit = item.viewerCanUpdate && !bodyHTML.isEmpty && state != .pending && !item.isSending && !item.isSaving ? editLink(item.id) : ""
            return card(
                author: item.actor, action: reviewAction(state), date: item.date, now: now, isSending: item.isSending, isSaving: item.isSaving, edit: edit,
                badge: reviewBadge(state), body: body, kind: "review"
            )
        case .commit:
            return ""
        case let .forcePushed(before, after):
            // Its changes are shown in the app, which needs both heads to find them.
            let show = before.flatMap { before in after.flatMap { ChangesLink(forcePushFrom: before, to: $0) } }
            let action = show.map { #"<a class="event-action" href="\#(escape($0.url.absoluteString))">Show changes</a>"# } ?? ""
            return event(item, now: now, icon: "↻", text: "force-pushed the branch from \(sha(before)) to \(sha(after))", action: action)
        case let .merged(commit, into):
            return event(item, now: now, icon: "⇥", text: "merged \(sha(commit)) into <code>\(escape(into))</code>", kind: "merged")
        case .closed:
            return event(item, now: now, icon: "×", text: "closed this", kind: "closed")
        case .reopened:
            return event(item, now: now, icon: "↺", text: "reopened this")
        case .readyForReview:
            return event(item, now: now, icon: "◉", text: "marked this ready for review")
        case let .reviewRequested(reviewer):
            let who = reviewer.map { "<strong>\(escape($0))</strong>" } ?? "someone"
            return event(item, now: now, icon: "◎", text: "requested a review from \(who)")
        }
    }

    private static func card(
        author: Participant?, action: String, date: Date, now: Date, isSending: Bool = false, isSaving: Bool = false, edit: String = "", badge: String = "",
        body: String, kind: String = "comment", reactions: String = ""
    ) -> String {
        """
        <article class="item \(kind)">\(avatar(author, size: 40))<div class="card">\
        <header>\(edit)\(login(author)) \(escape(action))\(badge) \(isSending ? sending : isSaving ? saving : time(date, now: now))</header>\
        \(body.isEmpty ? "" : #"<div class="body">\#(body)</div>"#)\(reactions)</div></article>

        """
    }

    /// A review comment's thread: where it is, the diff it's on, then every comment in it. A
    /// resolved thread starts folded, as on github.com. Its place, and "Show in diff", open it in
    /// the diff, and it ends with what the viewer may do to it, as `ThreadLink`s the app follows.
    private static func thread(for comment: ReviewComment, in thread: ReviewThread?, reviewer: Participant?, date: Date, now: Date) -> String {
        let isResolved = thread?.isResolved ?? false
        let isOutdated = thread?.isOutdated ?? comment.isOutdated
        let line = comment.line ?? thread?.line ?? comment.originalLine
        let location = line.map { "\(comment.path):\($0)" } ?? comment.path
        var place = "<code>\(escape(location))</code>"
        var showInDiff = ""
        var actions = ""
        if let thread {
            let show = escape(ThreadLink(.show, thread: thread.id).url.absoluteString)
            place = #"<a class="thread-location" href="\#(show)" title="Show in the diff">\#(place)</a>"#
            showInDiff = #"<a class="thread-show" href="\#(show)">Show in diff</a>"#
            actions = threadActions(thread)
        }
        var badges = ""
        if isOutdated { badges += #" <span class="badge outdated">Outdated</span>"# }
        if isResolved { badges += #" <span class="badge resolved">Resolved</span>"# }
        let comments = thread?.comments ?? [ThreadComment(id: comment.id, author: reviewer, createdAt: date, bodyHTML: comment.bodyHTML, isMinimized: comment.isMinimized)]
        let replies = comments.map { reply in
            let isSettled = !reply.isSending && !reply.isSaving
            let edit = commentActions(reply.id, canEdit: reply.viewerCanUpdate && isSettled, canDelete: (reply.viewerCanDelete || reply.isPending) && isSettled)
            let when = reply.isSending ? sending : reply.isSaving ? saving : time(reply.createdAt, now: now)
            return #"<div class="thread-comment">\#(avatar(reply.author, size: 24))<div><header>\#(edit)\#(login(reply.author)) \#(when)</header><div class="body">\#(minimizable(reply.bodyHTML, isMinimized: reply.isMinimized))</div>\#(reply.isPending || reply.isSending ? "" : reactions(reply.reactions, to: reply.id))</div></div>"#
        }.joined()
        let classes = ["thread", isResolved ? "resolved" : nil, isOutdated ? "outdated" : nil].compactMap { $0 }.joined(separator: " ")
        // The app finds the thread by its id, to put a reply to it beside it.
        let id = thread.map { #" data-thread-id="\#(escape($0.id))""# } ?? ""
        return #"<details class="\#(classes)"\#(id)\#(isResolved ? "" : " open")><summary>\#(place)\#(badges)\#(showInDiff)</summary>\#(hunk(comment.diffHunk))\#(replies)\#(actions)</details>"#
    }

    /// Reply, and resolve or unresolve, where the viewer may; a thread in the viewer's pending
    /// review takes neither until it's submitted, as in the diff.
    private static func threadActions(_ thread: ReviewThread) -> String {
        guard !thread.isPending else { return "" }
        var links: [String] = []
        if thread.viewerCanReply {
            links.append(#"<a class="thread-reply" href="\#(escape(ThreadLink(.reply, thread: thread.id).url.absoluteString))">Reply…</a>"#)
        }
        if thread.isResolved ? thread.viewerCanUnresolve : thread.viewerCanResolve {
            let action: ThreadLink.Action = thread.isResolved ? .unresolve : .resolve
            let label = thread.isResolved ? "Unresolve conversation" : "Resolve conversation"
            links.append(#"<a class="thread-\#(action.rawValue)" href="\#(escape(ThreadLink(action, thread: thread.id).url.absoluteString))">\#(label)</a>"#)
        }
        guard !links.isEmpty else { return "" }
        return #"<div class="thread-actions">\#(links.joined())</div>"#
    }

    /// A pill for each reaction anyone has made, the viewer's own marked, then a "+" that opens
    /// all eight; each is a `ReactionLink` the app follows, taking the viewer's away where
    /// they've made it and adding it where they haven't.
    private static func reactions(_ groups: [ReactionGroup], to subjectId: String) -> String {
        let pills = groups.map { group in
            let link = ReactionLink(group.viewerHasReacted ? .remove : .add, group.content, on: subjectId)
            let who = group.viewerHasReacted ? (group.count == 1 ? "You" : "You and \(group.count - 1) more") : "\(group.count) \(group.count == 1 ? "person" : "people")"
            return #"<a class="reaction\#(group.viewerHasReacted ? " reacted" : "")" href="\#(escape(link.url.absoluteString))" title="\#(who) reacted with \#(group.content.name)">\#(group.content.emoji)<span class="count">\#(group.count)</span></a>"#
        }.joined()
        let choices = Reaction.allCases.map { content in
            let reacted = groups.viewerHasReacted(content)
            let link = ReactionLink(reacted ? .remove : .add, content, on: subjectId)
            return #"<a class="\#(reacted ? "reacted" : "")" href="\#(escape(link.url.absoluteString))" title="\#(content.name)">\#(content.emoji)</a>"#
        }.joined()
        return #"<div class="reactions">\#(pills)<details class="reaction-picker"><summary title="Add a reaction">\#(smiley)</summary><div class="choices">\#(choices)</div></details></div>"#
    }

    /// The way to comment on the PR, after everything else as on github.com, as a `CommentLink`
    /// the app follows; the app finds it by its `data-new-comment`, to put the composer by it.
    private static let newComment = #"<div class="new-comment"><a href="\#(CommentLink().url.absoluteString)" data-new-comment>Add a comment…</a></div>"# + "\n"

    /// GitHub's quiet face for adding a reaction, drawn inline as the page loads nothing else.
    private static let smiley = #"<svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true"><circle cx="8" cy="8" r="6.75" fill="none" stroke="currentColor" stroke-width="1.5"/><circle cx="5.75" cy="6.5" r="1" fill="currentColor"/><circle cx="10.25" cy="6.5" r="1" fill="currentColor"/><path d="M5.25 9.75a3.25 3.25 0 0 0 5.5 0" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round"/></svg>"#

    /// The last few lines of the hunk, ending on the commented line, as github.com shows.
    private static func hunk(_ diffHunk: String) -> String {
        let lines = diffHunk.split(separator: "\n", omittingEmptySubsequences: false).filter { !$0.hasPrefix("@@") }.suffix(4)
        guard !lines.isEmpty else { return "" }
        let rows = lines.map { line in
            let kind = line.hasPrefix("+") ? "add" : line.hasPrefix("-") ? "del" : "ctx"
            return #"<span class="\#(kind)">\#(escape(String(line)))</span>"#
        }.joined(separator: "\n")
        return #"<pre class="hunk"><code>\#(rows)</code></pre>"#
    }

    private static func commitList(_ commits: [TimelineItem]) -> String {
        let rows = commits.map { item -> String in
            guard case let .commit(oid, headline) = item.event else { return "" }
            return #"<li>\#(avatar(item.actor, size: 20))<span class="headline">\#(escape(headline))</span><code class="sha">\#(escape(String(oid.prefix(7))))</code></li>"#
        }.joined()
        return #"<section class="item commits"><span class="icon">⎇</span><ul>\#(rows)</ul></section>"# + "\n"
    }

    private static func event(_ item: TimelineItem, now: Date, icon: String, text: String, kind: String = "", action: String = "") -> String {
        #"<div class="item event \#(kind)"><span class="icon">\#(icon)</span>\#(avatar(item.actor, size: 20))<span>\#(login(item.actor)) \#(text) \#(time(item.date, now: now))</span>\#(action)</div>"# + "\n"
    }

    private static func checks(_ checks: [CheckContext]) -> String {
        guard !checks.isEmpty else { return "" }
        let failing = checks.count { $0.status == .failure }
        let pending = checks.count { $0.status == .pending }
        let summary = failing > 0 ? "\(failing) failing" : pending > 0 ? "\(pending) pending" : "All checks have passed"
        let rows = checks.map { check -> String in
            let name = safeURL(check.url).map { #"<a href="\#($0)">\#(escape(check.name))</a>"# } ?? escape(check.name)
            let description = check.description.map { #" <span class="muted">\#(escape($0))</span>"# } ?? ""
            return #"<li class="check \#(check.status.rawValue)"><span class="status">\#(statusIcon(check.status))</span>\#(name)\#(description)</li>"#
        }.joined()
        return #"<section class="checks"><h2>Checks <span class="muted">\#(escape(summary))</span></h2><ul>\#(rows)</ul></section>"# + "\n"
    }

    private static func minimizable(_ bodyHTML: String, isMinimized: Bool) -> String {
        isMinimized ? #"<details class="minimized"><summary>This comment was hidden.</summary>\#(bodyHTML)</details>"# : bodyHTML
    }

    private static func avatar(_ participant: Participant?, size: Int) -> String {
        guard let url = safeURL(participant?.avatarURL) else { return #"<span class="avatar" style="width:\#(size)px;height:\#(size)px"></span>"# }
        // Asked for at twice the size, for Retina screens.
        let sized = url + (url.contains("?") ? "&amp;" : "?") + "s=\(size * 2)"
        return #"<img class="avatar" src="\#(sized)" width="\#(size)" height="\#(size)" alt="">"#
    }

    private static func login(_ participant: Participant?) -> String {
        "<strong>\(escape(participant?.login ?? "ghost"))</strong>"
    }

    /// In place of the time of the viewer's comment or review on its way to GitHub.
    private static let sending = #"<span class="muted sending">Sending…</span>"#

    /// In place of the time of the viewer's comment or review while their edit of it is on its
    /// way to GitHub.
    private static let saving = #"<span class="muted saving">Saving…</span>"#

    /// Edits the viewer's comment or review with `id`, as a `CommentLink` the app follows; the
    /// app finds it by its `data-edit-comment`, to put the editor by it.
    private static func editLink(_ id: String) -> String {
        #"<a class="comment-edit" href="\#(escape(CommentLink(editing: id).url.absoluteString))" data-edit-comment="\#(escape(id))">Edit</a>"#
    }

    /// "Edit" and "Delete" for the viewer's comment with `id`, as far as they may; floated to
    /// the end of its header, Delete last.
    private static func commentActions(_ id: String, canEdit: Bool, canDelete: Bool) -> String {
        let delete = canDelete ? #"<a class="comment-delete" href="\#(escape(CommentLink(deleting: id).url.absoluteString))">Delete</a>"# : ""
        return delete + (canEdit ? editLink(id) : "")
    }

    /// A relative time, which `RelativeTimes` keeps current by its `datetime`, the full date
    /// shown on hover.
    private static func time(_ date: Date, now: Date) -> String {
        let relative = date.ago(now: now, locale: Locale(identifier: "en_US"))
        let full = date.formatted(Date.FormatStyle(date: .complete, time: .shortened))
        return #"<time datetime="\#(date.formatted(.iso8601))" title="\#(escape(full))">\#(escape(relative))</time>"#
    }

    private static func reviewAction(_ state: ReviewState) -> String {
        switch state {
        case .approved: "approved these changes"
        case .changesRequested: "requested changes"
        case .dismissed: "reviewed"
        case .pending: "started a review"
        case .commented, .unknown: "reviewed"
        }
    }

    private static func reviewBadge(_ state: ReviewState) -> String {
        let (label, kind) = switch state {
        case .approved: ("Approved", "approved")
        case .changesRequested: ("Changes requested", "changes-requested")
        case .commented: ("Commented", "commented")
        case .dismissed: ("Dismissed", "dismissed")
        case .pending: ("Pending", "pending")
        case .unknown: ("Reviewed", "commented")
        }
        return #" <span class="badge \#(kind)">\#(label)</span>"#
    }

    private static func statusIcon(_ status: CheckStatus) -> String {
        switch status {
        case .success: "✓"
        case .failure: "✗"
        case .pending: "●"
        case .neutral: "–"
        }
    }

    private static func sha(_ oid: String?) -> String {
        oid.map { "<code>\(escape(String($0.prefix(7))))</code>" } ?? "an earlier commit"
    }

    /// The URL escaped for an attribute, if it's https; anything else could be script.
    private static func safeURL(_ url: String?) -> String? {
        guard let url, url.lowercased().hasPrefix("https://") else { return nil }
        return escape(url)
    }

    /// Safe as text and inside a quoted attribute.
    static func escape(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": escaped += "&amp;"
            case "<": escaped += "&lt;"
            case ">": escaped += "&gt;"
            case "\"": escaped += "&quot;"
            case "'": escaped += "&#39;"
            default: escaped.append(character)
            }
        }
        return escaped
    }
}

/// A force-push's "Show changes" in the conversation page, which shows the files with what the
/// push changed picked. Caught by its web view as `ThreadLink`s are.
public struct ChangesLink: Sendable, Equatable {
    /// The head the push replaced.
    public let before: String
    /// The head it pushed.
    public let after: String

    /// Nil unless both are commit oids, the only thing the link carries.
    public init?(forcePushFrom before: String, to after: String) {
        guard Self.isOid(before), Self.isOid(after) else { return nil }
        self.before = before
        self.after = after
    }

    /// The link a page names, if it's one of these.
    public init?(url: URL) {
        let oids = url.path(percentEncoded: false).split(separator: "/")
        guard url.scheme == Self.scheme, url.host() == "force-push", oids.count == 2 else { return nil }
        self.init(forcePushFrom: String(oids[0]), to: String(oids[1]))
    }

    /// `loupe-changes://force-push/<before>/<after>`.
    public var url: URL {
        // Both are hex, so this always parses.
        URL(string: "\(Self.scheme)://force-push/\(before)/\(after)")!
    }

    private static let scheme = "loupe-changes"

    private static func isOid(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy(\.isHexDigit)
    }
}

/// A link in the conversation page that acts on one of its review threads in the app: shows it
/// in the diff, opens a reply to it, or resolves or unresolves it. The page runs no script, so
/// its web view catches these as they're followed.
public struct ThreadLink: Sendable, Equatable {
    public enum Action: String, Sendable {
        case show
        case reply
        case resolve
        case unresolve
    }

    public let action: Action
    /// The thread's GraphQL id.
    public let threadId: String

    public init(_ action: Action, thread threadId: String) {
        self.action = action
        self.threadId = threadId
    }

    /// The link a page names, if it's one of these.
    public init?(url: URL) {
        guard url.scheme == Self.scheme, let action = url.host().flatMap(Action.init(rawValue:)) else { return nil }
        let id = url.path(percentEncoded: false).trimmingPrefix("/")
        guard !id.isEmpty else { return nil }
        self.init(action, thread: String(id))
    }

    /// `loupe-thread://<action>/<thread id>`.
    public var url: URL {
        let id = threadId.addingPercentEncoding(withAllowedCharacters: Self.idCharacters) ?? threadId
        // Only the id varies, and it's percent-encoded, so this always parses.
        return URL(string: "\(Self.scheme)://\(action.rawValue)/\(id)")!
    }

    private static let scheme = "loupe-thread"
    private static let idCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
}

/// A link in the conversation page that adds the viewer's reaction to the description, a
/// comment, a review or a thread comment, or takes it away. Caught by its web view as
/// `ThreadLink`s are.
public struct ReactionLink: Sendable, Equatable {
    public enum Action: String, Sendable {
        case add
        case remove
    }

    public let action: Action
    public let content: Reaction
    /// The GraphQL id of what's reacted to.
    public let subjectId: String

    public init(_ action: Action, _ content: Reaction, on subjectId: String) {
        self.action = action
        self.content = content
        self.subjectId = subjectId
    }

    /// The link a page names, if it's one of these.
    public init?(url: URL) {
        guard url.scheme == Self.scheme, let action = url.host().flatMap(Action.init(rawValue:)) else { return nil }
        // Split before decoding, as an id can hold an encoded slash.
        let parts = url.path(percentEncoded: true).split(separator: "/")
        guard parts.count == 2, let id = parts[0].removingPercentEncoding, !id.isEmpty, let content = Reaction(rawValue: String(parts[1])) else { return nil }
        self.init(action, content, on: id)
    }

    /// `loupe-reaction://<add|remove>/<subject id>/<content>`.
    public var url: URL {
        let id = subjectId.addingPercentEncoding(withAllowedCharacters: Self.idCharacters) ?? subjectId
        // Only the id varies, and it's percent-encoded, so this always parses.
        return URL(string: "\(Self.scheme)://\(action.rawValue)/\(id)/\(content.rawValue)")!
    }

    private static let scheme = "loupe-reaction"
    private static let idCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
}

/// A link in the conversation page that writes a comment: at its foot, one on the PR itself, as
/// github.com's box there does, or on one of the viewer's comments or reviews, an edit of it.
/// Caught by its web view as `ThreadLink`s are.
public struct CommentLink: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        case new
        /// The GraphQL id of the comment, thread comment or review to edit.
        case edit(String)
        /// The GraphQL id of the comment or thread comment to delete.
        case delete(String)
    }

    public let target: Target

    /// A new comment on the PR.
    public init() {
        target = .new
    }

    /// An edit of the comment or review with `id`.
    public init(editing id: String) {
        target = .edit(id)
    }

    /// A deletion of the comment with `id`.
    public init(deleting id: String) {
        target = .delete(id)
    }

    /// The link a page names, if it's one of these.
    public init?(url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        switch url.host() {
        case "new":
            self.init()
        case "edit", "delete":
            let id = String(url.path(percentEncoded: false).trimmingPrefix("/"))
            guard !id.isEmpty else { return nil }
            self.init(target: url.host() == "edit" ? .edit(id) : .delete(id))
        default:
            return nil
        }
    }

    private init(target: Target) {
        self.target = target
    }

    /// `loupe-comment://new`, `loupe-comment://edit/<id>` or `loupe-comment://delete/<id>`.
    public var url: URL {
        switch target {
        case .new:
            // Fixed, so this always parses.
            return URL(string: "\(Self.scheme)://new")!
        case let .edit(id):
            return Self.url("edit", id)
        case let .delete(id):
            return Self.url("delete", id)
        }
    }

    private static let scheme = "loupe-comment"
    private static let idCharacters = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))

    private static func url(_ action: String, _ id: String) -> URL {
        let encoded = id.addingPercentEncoding(withAllowedCharacters: idCharacters) ?? id
        // Only the id varies, and it's percent-encoded, so this always parses.
        return URL(string: "\(scheme)://\(action)/\(encoded)")!
    }
}
