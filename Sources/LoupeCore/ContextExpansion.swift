/// A request to show more of a file's unchanged lines beside one of its hunks, as GitHub's
/// expand arrows do.
public struct ContextExpansion: Sendable, Hashable {
    public enum Direction: Sendable, Hashable {
        case above, below
    }

    /// How many lines one click reveals, as on GitHub.
    public static let step = 20

    /// Which hunk to expand from, by index into the file's hunks as shown.
    public var hunk: Int
    public var direction: Direction
    /// How many lines to reveal, or nil for all of them up to the neighbouring hunk or the
    /// file's end.
    public var lines: Int?

    public init(hunk: Int, direction: Direction, lines: Int? = ContextExpansion.step) {
        self.hunk = hunk
        self.direction = direction
        self.lines = lines
    }
}

/// What the renderer needs to offer expanding a file's unchanged lines. Given only for a file
/// whose text can be read to fill them in.
public struct ExpandableContext: Sendable, Equatable {
    /// How many lines the new file has, once read; until then nothing is offered below the
    /// last hunk.
    public var newLineCount: Int?

    public init(newLineCount: Int? = nil) {
        self.newLineCount = newLineCount
    }
}

public extension FileDiff {
    /// This diff with more of the new file's unchanged lines shown beside a hunk, given the new
    /// file's lines. Lines outside hunks are the same on both sides, so revealed lines are
    /// context, numbered on the old side by the offset the changes before them leave. A hunk
    /// that reaches its neighbour is merged with it, keeping the earlier one's function context.
    func expanding(_ expansion: ContextExpansion, newFile: [String]) -> FileDiff {
        guard hunks.indices.contains(expansion.hunk) else { return self }
        let index = expansion.hunk
        let hunk = hunks[index]
        var expanded = self
        switch expansion.direction {
        case .above:
            let first = hunk.newLines.lowerBound
            let hidden = hiddenLines(above: index)
            let count = min(expansion.lines ?? hidden, hidden)
            guard count > 0, first - 1 <= newFile.count else { return self }
            let offset = hunk.oldLines.lowerBound - first
            let revealed = (first - count..<first).map { DiffLine(kind: .context(old: $0 + offset, new: $0), text: newFile[$0 - 1]) }
            expanded.hunks[index].lines.insert(contentsOf: revealed, at: 0)
            if count == hidden, index > 0 {
                expanded.mergeHunk(index - 1)
            } else {
                expanded.hunks[index].reheader()
            }
        case .below:
            let end = hunk.newLines.upperBound
            let ceiling = index + 1 < hunks.count ? hunks[index + 1].newLines.lowerBound : newFile.count + 1
            let hidden = ceiling - end
            let count = min(expansion.lines ?? hidden, hidden)
            guard count > 0, end + count - 1 <= newFile.count else { return self }
            let offset = hunk.oldLines.upperBound - end
            let revealed = (end..<end + count).map { DiffLine(kind: .context(old: $0 + offset, new: $0), text: newFile[$0 - 1]) }
            expanded.hunks[index].lines.append(contentsOf: revealed)
            if count == hidden, index + 1 < hunks.count {
                expanded.mergeHunk(index)
            } else {
                expanded.hunks[index].reheader()
            }
        }
        return expanded
    }

    /// How many unchanged lines are hidden between a hunk and the one before it, or the start
    /// of the file.
    func hiddenLines(above hunk: Int) -> Int {
        let floor = hunk > 0 ? hunks[hunk - 1].newLines.upperBound : 1
        return max(0, hunks[hunk].newLines.lowerBound - floor)
    }

    /// How many unchanged lines are hidden after the last hunk, in a new file of `newLineCount`.
    func hiddenLinesAfterLastHunk(newLineCount: Int) -> Int {
        guard let last = hunks.last else { return 0 }
        return max(0, newLineCount + 1 - last.newLines.upperBound)
    }

    /// Whether a diff of this file can show more of it: not when it's binary, or added or
    /// deleted, as one side then is the whole file and the other is empty.
    var canExpandContext: Bool {
        guard !isBinary, !hunks.isEmpty else { return false }
        switch change {
        case .added, .deleted: return false
        case .modified, .renamed, .copied: return true
        }
    }

    /// Splits a file's text into lines as git numbers them, keeping any "\r" as the diff does.
    static func lines(of text: String) -> [String] {
        var lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { String(Substring($0)) }
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines
    }
}

public extension Hunk {
    /// The new file's lines this hunk covers. An empty side is placed after the line its
    /// header's start names, as git writes it.
    var newLines: Range<Int> { Self.span(start: newStart, count: lines.count { $0.newLine != nil }) }

    /// The old file's lines this hunk covers.
    var oldLines: Range<Int> { Self.span(start: oldStart, count: lines.count { $0.oldLine != nil }) }
}

private extension FileDiff {
    /// Joins hunk `index` with the next, whose lines now follow on from its own.
    mutating func mergeHunk(_ index: Int) {
        hunks[index].lines += hunks[index + 1].lines
        hunks.remove(at: index + 1)
        hunks[index].reheader()
    }
}

private extension Hunk {
    static func span(start: Int, count: Int) -> Range<Int> {
        let first = count == 0 ? start + 1 : start
        return first..<first + count
    }

    /// Recounts the header's ranges from the lines, keeping its function context, in git's
    /// form, which leaves out a count of one.
    mutating func reheader() {
        let old = lines.compactMap(\.oldLine)
        let new = lines.compactMap(\.newLine)
        oldStart = old.first ?? oldLines.lowerBound - 1
        newStart = new.first ?? newLines.lowerBound - 1
        func range(_ start: Int, _ count: Int) -> String { count == 1 ? "\(start)" : "\(start),\(count)" }
        header = "@@ -\(range(oldStart, old.count)) +\(range(newStart, new.count)) @@" + section
    }
}
