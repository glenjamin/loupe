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

/// What the viewer has opened up among a tab's threads, kept while the tab lives so moving
/// between files doesn't fold them again.
@Observable
@MainActor
public final class ThreadActivity {
    /// Resolved threads opened to read, and hidden comments shown, by id.
    public var expanded: Set<String> = []

    init() {}
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
