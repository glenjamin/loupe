import Foundation
import LoupeCore
import LoupeModel

extension PullRequestTab {
    /// The text a suggestion on a new comment at `anchor` starts from: its line on the new side,
    /// from the whole PR's diff. Nil on a deleted line, as github.com offers no suggestion there.
    public func suggestedLines(at anchor: DiffAnchor) -> [String]? {
        guard anchor.side == .right else { return nil }
        return newSideText(of: anchor.line...anchor.line, in: anchor.path)
    }

    /// The text a suggestion in a reply to `thread` starts from: every line it's on, on the new
    /// side. Nil for a thread on deleted lines, on the whole file, or outdated, as there's no
    /// current text to change.
    public func suggestedLines(for thread: ReviewThread) -> [String]? {
        guard thread.side == .right, !thread.isOutdated, !thread.isOnFile, thread.line != nil, let lines = thread.lines else { return nil }
        return newSideText(of: lines, in: thread.path)
    }

    /// The new side's text of `lines` of the file at `path` in the whole PR's diff, with any
    /// lines revealed around its hunks while it's shown; nil unless every line is there.
    private func newSideText(of lines: ClosedRange<Int>, in path: String) -> [String]? {
        guard case let .ready(review) = phase else { return nil }
        let produced: FileDiff?
        if shownChoice == .all {
            let hidden: FileDiff? = if case let .ready(file)? = hiddenFileDiff(of: path) { file } else { nil }
            produced = (review.changes.files.first { $0.path == path } ?? hidden).map(expandedFile)
        } else {
            produced = review.changes.files.first { $0.path == path }
        }
        guard let file = produced else { return nil }
        var texts: [Int: String] = [:]
        for line in file.hunks.flatMap(\.lines) {
            if let number = line.newLine, lines.contains(number) { texts[number] = line.text }
        }
        let found = lines.compactMap { texts[$0] }
        return found.count == lines.count ? found : nil
    }
}
