import Foundation
import LoupeModel

/// A PR's conversation as one HTML page, from a template with `{{stylesheet}}`, `{{layout}}` and
/// `{{content}}` in it. GitHub's `bodyHTML` fragments go in verbatim, as GitHub has already rendered and
/// sanitised them; every other string is escaped.
public enum ConversationHTML {
    /// The page for `conversation`, or a placeholder saying it's loading or why it failed.
    public static func page(_ conversation: Conversation?, error: String? = nil, template: String, stylesheet: String, now: Date = .now) -> String {
        let content = if let conversation {
            render(conversation, now: now)
        } else if let error {
            #"<p class="placeholder">Couldn't load the conversation: \#(escape(error))</p>"#
        } else {
            #"<p class="placeholder">Loading the conversation…</p>"#
        }
        return fill(template, layout: "timeline", content: content, stylesheet: stylesheet)
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
            body: conversation.bodyHTML.isEmpty ? #"<p class="muted">No description provided.</p>"# : conversation.bodyHTML
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
        return html
    }

    private static func render(_ item: TimelineItem, threads: [String: ReviewThread], now: Date) -> String {
        switch item.event {
        case let .comment(bodyHTML, isMinimized):
            return card(author: item.actor, action: "commented", date: item.date, now: now, body: minimizable(bodyHTML, isMinimized: isMinimized))
        case let .review(state, bodyHTML, comments):
            // Replies are shown in their threads, under the review that started them.
            let started = comments.filter { $0.replyTo == nil }
            if bodyHTML.isEmpty, started.isEmpty, state == .commented { return "" }
            let body = (bodyHTML.isEmpty ? "" : bodyHTML) + started.map { thread(for: $0, in: threads[$0.id], reviewer: item.actor, date: item.date, now: now) }.joined()
            return card(author: item.actor, action: reviewAction(state), date: item.date, now: now, badge: reviewBadge(state), body: body, kind: "review")
        case .commit:
            return ""
        case let .forcePushed(before, after):
            return event(item, now: now, icon: "↻", text: "force-pushed the branch from \(sha(before)) to \(sha(after))")
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

    private static func card(author: Participant?, action: String, date: Date, now: Date, badge: String = "", body: String, kind: String = "comment") -> String {
        """
        <article class="item \(kind)">\(avatar(author, size: 40))<div class="card">\
        <header>\(login(author)) \(escape(action))\(badge) \(time(date, now: now))</header>\
        \(body.isEmpty ? "" : #"<div class="body">\#(body)</div>"#)</div></article>

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
            #"<div class="thread-comment">\#(avatar(reply.author, size: 24))<div><header>\#(login(reply.author)) \#(time(reply.createdAt, now: now))</header><div class="body">\#(minimizable(reply.bodyHTML, isMinimized: reply.isMinimized))</div></div></div>"#
        }.joined()
        let classes = ["thread", isResolved ? "resolved" : nil, isOutdated ? "outdated" : nil].compactMap { $0 }.joined(separator: " ")
        return #"<details class="\#(classes)"\#(isResolved ? "" : " open")><summary>\#(place)\#(badges)\#(showInDiff)</summary>\#(hunk(comment.diffHunk))\#(replies)\#(actions)</details>"#
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

    private static func event(_ item: TimelineItem, now: Date, icon: String, text: String, kind: String = "") -> String {
        #"<div class="item event \#(kind)"><span class="icon">\#(icon)</span>\#(avatar(item.actor, size: 20))<span>\#(login(item.actor)) \#(text) \#(time(item.date, now: now))</span></div>"# + "\n"
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

    private static func time(_ date: Date, now: Date) -> String {
        let relative = date.formatted(.relative(presentation: .named).locale(Locale(identifier: "en_US")))
        let exact = date.formatted(.iso8601)
        return #"<time datetime="\#(exact)" title="\#(exact)">\#(escape(date > now ? "just now" : relative))</time>"#
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
