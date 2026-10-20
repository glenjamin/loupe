import CryptoKit
import Foundation
import LoupeCore
import LoupeModel

/// A place in the conversation a link landed on, for its page to scroll to and mark.
public struct ConversationLanding: Sendable, Equatable {
    /// The GraphQL ids of what to land on, the most particular first: a comment, then the
    /// thread it's in, which the page shows in its place if it doesn't show the comment.
    public let ids: [String]
    /// Which landing this is, so landing on the same place again marks it again.
    let serial: Int
}

extension PullRequestTab {
    /// Shows what a link to the PR points at: a comment or review in the conversation, scrolled
    /// to and marked; a review thread's comment on its line in the whole PR's diff, as "Show in
    /// diff" does, or in the conversation if it's outdated or the diff has no line for it; or
    /// the files, a commit's and a file among them as the link names. Waits for the
    /// conversation, or the diff, where it needs them; gives up if another landing starts, or
    /// the viewer moves to the other section, meanwhile.
    public func land(on target: PullRequestLink.Target) async {
        landings += 1
        let landing = landings
        conversationLanding = nil
        switch target {
        case let .comment(id):
            await landInConversation(landing) { conversation in
                conversation.items.first { $0.databaseId == id && $0.isComment }.map { [$0.id] }
            }
        case let .review(id):
            await landInConversation(landing) { conversation in
                conversation.items.first { $0.databaseId == id && $0.isReview }.map { [$0.id] }
            }
        case let .reviewComment(id):
            await landOnReviewComment(id, landing)
        case let .files(commit, fileHash):
            await landInFiles(commit: commit, fileHash: fileHash, landing)
        }
    }

    /// Called once the conversation's page has scrolled to the landing and marked it, or found
    /// it has nothing to mark.
    public func didLand(_ landing: ConversationLanding) {
        if conversationLanding == landing { conversationLanding = nil }
    }

    /// Shows the conversation and, once it has what `find` looks for, lands there; with nothing
    /// found, the conversation is shown as it is.
    private func landInConversation(_ landing: Int, find: (Conversation) -> [String]?) async {
        section = .conversation
        guard let ids = await findInConversation(find), isStill(landing, on: .conversation) else { return }
        conversationLanding = ConversationLanding(ids: ids, serial: landing)
    }

    /// Lands on the thread comment with REST id `id` in the diff, or in the conversation where
    /// the diff has no line for it. The files are shown while the diff is made once the thread
    /// is known to have a line.
    private func landOnReviewComment(_ id: Int, _ landing: Int) async {
        let find = { (conversation: Conversation) in conversation.threads.first { $0.comments.contains { $0.databaseId == id } } }
        guard let thread = await findInConversation(find), landing == landings else {
            if landing == landings { section = .conversation }
            return
        }
        let ids = (thread.comments.first { $0.databaseId == id }.map { [$0.id] } ?? []) + [thread.id]
        func landInConversation() {
            section = .conversation
            conversationLanding = ConversationLanding(ids: ids, serial: landing)
        }
        guard thread.hasLine else { return landInConversation() }
        section = .files
        await load()
        guard isStill(landing, on: .files) else { return }
        guard let current = conversation.flatMap(find), await isOnALineOfTheDiff(current), isStill(landing, on: .files) else {
            return landInConversation()
        }
        await showInDiff(current)
    }

    /// Shows the files, once the diff is made: the commit's changes if the link names one of
    /// the PR's commits, otherwise the whole PR's, and the file whose path hashes to
    /// `fileHash`, as github.com's `#diff-…` anchors do.
    private func landInFiles(commit: String?, fileHash: String?, _ landing: Int) async {
        section = .files
        await load()
        guard isStill(landing, on: .files), case let .ready(review) = phase else { return }
        let picked = commit.flatMap { commit in review.commits.first { $0.oid.hasPrefix(commit.lowercased()) } }
        let choice = picked.map { ChangesChoice.commit($0.oid) } ?? .all
        if shownChoice != choice || pendingChoice != nil { await show(choice) }
        guard isStill(landing, on: .files), let fileHash, case let .ready(changes)? = shownChanges else { return }
        let paths = changes.files.map(\.path) + changes.hidden.map(\.path)
        if let path = paths.first(where: { gitHubDiffAnchor(of: $0) == fileHash }) { selectedFile = path }
    }

    /// What `find` finds in the conversation: as stored, or once it's been fetched. A fetch
    /// underway is waited for; one is started if the stored conversation hasn't it, as a comment
    /// may be newer, or stored before its REST id was.
    private func findInConversation<Found>(_ find: (Conversation) -> Found?) async -> Found? {
        if let found = conversation.flatMap(find) { return found }
        if !hasStartedLoading {
            // As showing the tab would; only the conversation is waited for.
            Task { await load() }
        } else if !isFetchingConversation {
            await refreshConversation()
            return conversation.flatMap(find)
        }
        await withCheckedContinuation { conversationWaiters.append($0) }
        return conversation.flatMap(find)
    }

    /// Whether the thread is on one of the lines the whole PR's diff shows, rather than after
    /// its file's last row. A hidden file is diffed to find out.
    private func isOnALineOfTheDiff(_ thread: ReviewThread) async -> Bool {
        guard whyDiffCannotShow(thread) == nil, let line = thread.line, case let .ready(review) = phase else { return false }
        if let file = review.changes.files.first(where: { $0.path == thread.path }) {
            return file.has(line, on: thread.side)
        }
        if shownChoice != .all { await show(.all) }
        await diffHiddenFile(thread.path)
        guard case let .ready(file)? = hiddenFileDiff(of: thread.path) else { return false }
        return file.has(line, on: thread.side)
    }

    /// Whether the landing is still the latest and the viewer is still on the section it showed.
    private func isStill(_ landing: Int, on section: ReviewSection) -> Bool {
        landing == landings && self.section == section
    }
}

/// GitHub's anchor for a file in a PR's files, `diff-` and this: the SHA-256 of its path, in
/// lowercase hex.
func gitHubDiffAnchor(of path: String) -> String {
    SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
}

private extension ReviewThread {
    /// On a line of the current diff, rather than outdated or on the whole file.
    var hasLine: Bool {
        !isOutdated && !isOnFile && line != nil
    }
}

private extension TimelineItem {
    var isComment: Bool {
        if case .comment = event { true } else { false }
    }

    var isReview: Bool {
        if case .review = event { true } else { false }
    }
}
