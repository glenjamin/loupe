import Foundation
import LoupeCore
import LoupeModel
import Observation

/// A file's review threads as its diff shows them: each under the line it ends on, and the
/// rest, outdated, on the whole file or on a line the diff doesn't have, after the last row.
public struct FileThreads: Sendable, Equatable {
    /// Threads on lines in the diff, in the order GitHub lists them, grouped by line.
    public var anchored: [LineThreads]
    /// Threads with nowhere in the diff to go, in the order GitHub lists them.
    public var elsewhere: [ReviewThread]

    public var isEmpty: Bool { anchored.isEmpty && elsewhere.isEmpty }
}

/// The threads ending on one line of a diff.
public struct LineThreads: Sendable, Equatable {
    public var side: DiffAnchor.Side
    public var line: Int
    public var threads: [ReviewThread]
}

/// What the viewer is doing among a tab's threads: what they've opened up, the replies being
/// written, and changes on their way to GitHub. Kept while the tab lives, so moving between
/// files doesn't fold threads again or lose a draft.
@Observable
@MainActor
public final class ThreadActivity {
    /// Resolved threads opened to read, and hidden comments shown, by id.
    public var expanded: Set<String> = []
    /// The reply being written to each thread, by thread id.
    public internal(set) var replies: [String: CommentDraft] = [:]
    /// Why the last reply to, or change to, each thread didn't reach GitHub, by thread id.
    public internal(set) var errors: [String: String] = [:]
    /// Threads being resolved or unresolved, by id.
    public internal(set) var resolving: Set<String> = []

    init() {}
}

/// A comment being written, as markdown.
@Observable
@MainActor
public final class CommentDraft {
    public var text = ""
    public internal(set) var isSending = false

    init() {}

    /// Whether there's anything to send.
    public var canSend: Bool {
        !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether closing it would lose something typed.
    public var hasText: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

extension PullRequestTab {
    /// The PR's review threads on `file`, as shown with any lines revealed around its hunks.
    /// Nil when one commit's changes are shown: threads belong to the whole PR's diff.
    public func threads(on file: FileDiff) -> FileThreads? {
        guard shownCommit == nil, let conversation else { return nil }
        var anchored: [LineThreads] = []
        var elsewhere: [ReviewThread] = []
        for thread in conversation.threads where thread.path == file.path {
            guard !thread.isOutdated, !thread.isOnFile, let line = thread.line, file.has(line, on: thread.side) else {
                elsewhere.append(thread)
                continue
            }
            let side = DiffAnchor.Side(thread.side)
            if let index = anchored.firstIndex(where: { $0.side == side && $0.line == line }) {
                anchored[index].threads.append(thread)
            } else {
                anchored.append(LineThreads(side: side, line: line, threads: [thread]))
            }
        }
        return FileThreads(anchored: anchored, elsewhere: elsewhere)
    }

    /// How many threads on the file at `path` aren't resolved, hidden files' included. Nil when
    /// one commit's changes are shown, as its diff shows no threads.
    public func unresolvedThreadCount(of path: String) -> Int? {
        guard shownCommit == nil else { return nil }
        return conversation?.threads.count { $0.path == path && !$0.isResolved } ?? 0
    }

    /// Opens a reply under the thread, keeping one already being written.
    public func startReply(to thread: ReviewThread) {
        guard thread.viewerCanReply, threadActivity.replies[thread.id] == nil else { return }
        threadActivity.replies[thread.id] = CommentDraft()
    }

    /// Closes the thread's reply, dropping its draft; asking first is the view's job.
    public func cancelReply(to thread: ReviewThread) {
        guard threadActivity.replies[thread.id]?.isSending != true else { return }
        threadActivity.replies[thread.id] = nil
        threadActivity.errors[thread.id] = nil
    }

    /// Posts the thread's reply at once, then fetches the threads again to show it as GitHub
    /// has it. A refusal keeps the draft open with the reason.
    public func sendReply(to thread: ReviewThread) async {
        guard let draft = threadActivity.replies[thread.id], draft.canSend else { return }
        guard let first = thread.comments.first?.databaseId else {
            threadActivity.errors[thread.id] = "Couldn't reply: GitHub hasn't said which comment started this thread. Reload and try again."
            return
        }
        draft.isSending = true
        threadActivity.errors[thread.id] = nil
        defer { draft.isSending = false }
        let pullRequest = pullRequest
        do {
            try await client.replyToThread(startedBy: first, body: draft.text, inPullRequest: pullRequest.number, of: pullRequest.repository)
        } catch {
            threadActivity.errors[thread.id] = "Couldn't reply: \(error.localizedDescription)"
            return
        }
        if threadActivity.replies[thread.id] === draft { threadActivity.replies[thread.id] = nil }
        await refreshThreads()
    }

    /// Resolves the thread, or unresolves it. The change shows at once, and is put back if
    /// GitHub refuses it; a thread resolved here folds away, as on github.com.
    public func setResolved(_ resolved: Bool, thread: ReviewThread) async {
        guard resolved ? thread.viewerCanResolve : thread.viewerCanUnresolve, !threadActivity.resolving.contains(thread.id) else { return }
        threadActivity.resolving.insert(thread.id)
        threadActivity.errors[thread.id] = nil
        defer { threadActivity.resolving.remove(thread.id) }
        updateThread(thread.id) { $0.isResolved = resolved }
        if resolved { threadActivity.expanded.remove(thread.id) }
        do {
            try await client.setThreadResolved(resolved, threadId: thread.id)
        } catch {
            updateThread(thread.id) { $0.isResolved = !resolved }
            threadActivity.errors[thread.id] = "Couldn't \(resolved ? "resolve" : "unresolve") this conversation: \(error.localizedDescription)"
            if resolved { threadActivity.expanded.insert(thread.id) }
            return
        }
        await refreshThreads()
    }

    /// Takes the PR's review threads from GitHub alone, which is much cheaper than the whole
    /// conversation, and stores them. A failure keeps what's shown.
    func refreshThreads() async {
        let threads: [ReviewThread]
        do {
            threads = try await client.reviewThreads(ofPullRequest: id)
        } catch {
            log("Couldn't get the review threads of \(title): \(error.localizedDescription)")
            return
        }
        conversation?.threads = threads
        do {
            try await store.replaceThreads(of: id, with: threads)
        } catch {
            log("Couldn't store the review threads of \(title): \(error)")
        }
    }

    private func updateThread(_ id: String, _ change: (inout ReviewThread) -> Void) {
        guard var conversation, let index = conversation.threads.firstIndex(where: { $0.id == id }) else { return }
        change(&conversation.threads[index])
        self.conversation = conversation
    }
}

private extension FileDiff {
    /// Whether a row of the diff has `line` on `side`: the new side for RIGHT, the old for LEFT.
    func has(_ line: Int, on side: ReviewThread.Side) -> Bool {
        hunks.contains { hunk in
            hunk.lines.contains { (side == .right ? $0.newLine : $0.oldLine) == line }
        }
    }
}

private extension DiffAnchor.Side {
    init(_ side: ReviewThread.Side) {
        self = side == .left ? .left : .right
    }
}

private func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}
