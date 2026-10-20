import Foundation
import LoupeCore
import LoupeModel

extension PullRequestTab {
    /// The text a suggestion on a new comment starts from: the new side of every line it's on,
    /// from the changes it was started on, those of the whole PR or one commit. Nil when it ends
    /// on a deleted line, as github.com offers no suggestion there.
    public func suggestedLines(for comment: NewComment) -> [String]? {
        let anchor = comment.anchor
        guard anchor.side == .right, comment.target == commentTarget, let file = shownFile(anchor.path) else { return nil }
        guard let start = comment.start else { return newSideText(of: anchor.line...anchor.line, in: file) }
        guard let rows = file.anchors(from: start, to: anchor) else { return nil }
        let lines = rows.filter { $0.side == .right }.map(\.line)
        guard let first = lines.first else { return nil }
        return newSideText(of: first...anchor.line, in: file)
    }

    /// The text a suggestion in a reply to `thread` starts from: every line it's on in the
    /// changes shown, on the new side. Nil for a thread on deleted lines, on the whole file, or
    /// outdated, as there's no current text to change.
    public func suggestedLines(for thread: ReviewThread) -> [String]? {
        guard thread.side == .right, let lines = placedLines(of: thread), let file = shownFile(thread.path) else { return nil }
        return newSideText(of: lines, in: file)
    }

    /// The file at `path` in the changes shown, with any lines revealed around its hunks.
    private func shownFile(_ path: String) -> FileDiff? {
        producedFile(path).map(expandedFile)
    }

    /// The new side's text of `lines` of `file`; nil unless every line is there.
    private func newSideText(of lines: ClosedRange<Int>, in file: FileDiff) -> [String]? {
        var texts: [Int: String] = [:]
        for line in file.hunks.flatMap(\.lines) {
            if let number = line.newLine, lines.contains(number) { texts[number] = line.text }
        }
        let found = lines.compactMap { texts[$0] }
        return found.count == lines.count ? found : nil
    }
}
