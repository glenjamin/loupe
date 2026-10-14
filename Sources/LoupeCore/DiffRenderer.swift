import AppKit

/// Where a review comment would attach, in GitHub's terms: RIGHT is the new file, LEFT the old.
public struct DiffAnchor: Sendable, Equatable, CustomStringConvertible {
    public enum Side: String, Sendable { case left = "LEFT", right = "RIGHT" }

    public var path: String
    public var side: Side
    public var line: Int

    public init(path: String, side: Side, line: Int) {
        self.path = path
        self.side = side
        self.line = line
    }

    public var description: String { "\(path) \(side.rawValue) \(line)" }
}

/// What each rendered row is, so the view can paint full-width backgrounds and resolve clicks.
public enum RowKind: Int, Sendable {
    case context, addition, deletion, hunkHeader
}

public extension NSAttributedString.Key {
    static let diffRowKind = NSAttributedString.Key("Loupe.diffRowKind")
    /// Marks gutter text (line numbers and the +/- marker) so copying a selection yields plain code.
    static let diffGutter = NSAttributedString.Key("Loupe.diffGutter")
    /// The width of the gutter's tinted columns, measured from the start of the line.
    static let diffGutterWidth = NSAttributedString.Key("Loupe.diffGutterWidth")
    /// Marks the words that changed within a modified line, for a stronger tint than the row's.
    static let diffEmphasis = NSAttributedString.Key("Loupe.diffEmphasis")
}

/// One file's diff as a single attributed string, with a gutter of old/new line numbers.
public struct RenderedDiff {
    public let text: NSAttributedString
    /// UTF-16 offset where each row starts, ascending.
    public let rowStarts: [Int]
    /// The anchor for each row; nil for hunk headers.
    public let rowAnchors: [DiffAnchor?]
    /// The file's code, ready to highlight; nil when its language isn't known.
    public let syntax: SyntaxPlan?

    public init(file: FileDiff, fontSize: CGFloat = 12) {
        let width = max(3, String(file.maxLineNumber).count)
        // Two right-aligned numbers and the marker, two spaces apart, then a tab out to the code.
        let style = Style(fontSize: fontSize, gutterColumns: width * 2 + 5)
        let out = NSMutableString()
        var rows: [(start: Int, length: Int, gutter: Int, kind: RowKind)] = []
        var anchors: [DiffAnchor?] = []
        var syntax = SyntaxLanguage(path: file.path).map(SyntaxPlan.init)
        rows.reserveCapacity(file.rowCount)
        anchors.reserveCapacity(file.rowCount)

        func addRow(gutter: String, body: String, kind: RowKind, anchor: DiffAnchor?) {
            let start = out.length
            out.append(gutter)
            out.append(body)
            out.append("\n")
            rows.append((start, out.length - start, (gutter as NSString).length, kind))
            anchors.append(anchor)
        }

        var emphasis: [NSRange] = []

        for hunk in file.hunks {
            addRow(gutter: "\t", body: hunk.header, kind: .hunkHeader, anchor: nil)
            let firstLineRow = rows.count
            var newSide = SyntaxPlan.Side()
            var oldSide = SyntaxPlan.Side()
            for line in hunk.lines {
                let numbers = pad(line.oldLine, width) + "  " + pad(line.newLine, width) + "  "
                let body = displayText(line)
                switch line.kind {
                case .context(_, let new):
                    addRow(gutter: numbers + " \t", body: body, kind: .context, anchor: DiffAnchor(path: file.path, side: .right, line: new))
                case .addition(let new):
                    addRow(gutter: numbers + "+\t", body: body, kind: .addition, anchor: DiffAnchor(path: file.path, side: .right, line: new))
                case .deletion(let old):
                    addRow(gutter: numbers + "-\t", body: body, kind: .deletion, anchor: DiffAnchor(path: file.path, side: .left, line: old))
                }
                if syntax != nil, let row = rows.last {
                    let code = (target: row.start + row.gutter, length: row.length - row.gutter - 1)
                    if line.newLine != nil { newSide.append(line.text, mappedTo: code.target, length: code.length) }
                    if line.oldLine != nil { oldSide.append(line.text, mappedTo: line.isDeletion ? code.target : nil, length: code.length) }
                }
            }
            syntax?.sides += [newSide, oldSide]
            for (old, new) in modifiedPairs(hunk.lines) {
                let oldRow = rows[firstLineRow + old]
                let newRow = rows[firstLineRow + new]
                guard let changed = changedWords(displayText(hunk.lines[old]), displayText(hunk.lines[new])) else { continue }
                emphasis += changed.old.map { NSRange(location: oldRow.start + oldRow.gutter + $0.location, length: $0.length) }
                emphasis += changed.new.map { NSRange(location: newRow.start + newRow.gutter + $0.location, length: $0.length) }
            }
        }

        let attributed = NSMutableAttributedString(string: out as String, attributes: style.base)
        attributed.beginEditing()
        for row in rows {
            let full = NSRange(location: row.start, length: row.length)
            attributed.addAttribute(.diffRowKind, value: row.kind.rawValue, range: full)
            attributed.addAttributes(style.gutter, range: NSRange(location: row.start, length: row.gutter))
            if row.kind == .hunkHeader {
                attributed.addAttributes(style.hunkHeader, range: NSRange(location: row.start + row.gutter, length: row.length - row.gutter))
            }
        }
        for range in emphasis {
            attributed.addAttribute(.diffEmphasis, value: true, range: range)
        }
        attributed.endEditing()

        text = attributed
        self.syntax = syntax
        rowStarts = rows.map(\.start)
        rowAnchors = anchors
    }

    /// The row containing a UTF-16 character offset.
    public func row(at characterIndex: Int) -> Int? {
        guard !rowStarts.isEmpty, characterIndex >= 0, characterIndex < text.length else { return nil }
        var low = 0
        var high = rowStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if rowStarts[mid] <= characterIndex { low = mid } else { high = mid - 1 }
        }
        return low
    }

    public func anchor(at characterIndex: Int) -> DiffAnchor? {
        row(at: characterIndex).flatMap { rowAnchors[$0] }
    }
}

public extension RowKind {
    var background: NSColor? {
        switch self {
        case .context: nil
        case .addition: DiffColors.additionBackground
        case .deletion: DiffColors.deletionBackground
        case .hunkHeader: DiffColors.hunkHeaderBackground
        }
    }

    /// The gutter's tint, a shade darker than the row's so the numbers read as separate from the code.
    var gutterBackground: NSColor? {
        switch self {
        case .context: nil
        case .addition: DiffColors.additionGutterBackground
        case .deletion: DiffColors.deletionGutterBackground
        case .hunkHeader: DiffColors.hunkHeaderGutterBackground
        }
    }

    /// The tint for words that changed within a modified line, drawn over the row's.
    var emphasisBackground: NSColor? {
        switch self {
        case .addition: DiffColors.additionWordBackground
        case .deletion: DiffColors.deletionWordBackground
        case .context, .hunkHeader: nil
        }
    }
}

private struct Style {
    let base: [NSAttributedString.Key: Any]
    let gutter: [NSAttributedString.Key: Any]
    let hunkHeader: [NSAttributedString.Key: Any]

    init(fontSize: CGFloat, gutterColumns: Int) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        // The tint runs a little past the marker; the code starts a little past the tint.
        let gutterWidth = digit * CGFloat(gutterColumns) + (fontSize / 3).rounded()
        let codeStart = gutterWidth + (fontSize * 2 / 3).rounded()
        let paragraph = NSMutableParagraphStyle()
        // Rows are about 20pt at 12pt, as on GitHub, with the extra space split above and below the text.
        let natural = ceil(font.ascender - font.descender + font.leading)
        let extra = max(0, (fontSize * 5 / 3).rounded() - natural)
        paragraph.minimumLineHeight = natural + (extra / 2).rounded(.down)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.lineSpacing = extra - (extra / 2).rounded(.down)
        // The gutter's tab lands on the code column, where wrapped lines hang too; tabs in the code
        // then step four columns from there.
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = codeStart
        paragraph.tabStops = (0..<32).map { NSTextTab(textAlignment: .left, location: codeStart + digit * 4 * CGFloat($0)) }
        paragraph.defaultTabInterval = digit * 4
        base = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph, .diffGutterWidth: gutterWidth]
        gutter = [.foregroundColor: NSColor.tertiaryLabelColor, .diffGutter: true]
        hunkHeader = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold),
        ]
    }
}

private extension FileDiff {
    var rowCount: Int { hunks.reduce(0) { $0 + $1.lines.count + 1 } }

    var maxLineNumber: Int {
        hunks.last.map { hunk in
            hunk.lines.reduce(max(hunk.oldStart, hunk.newStart)) { max($0, $1.oldLine ?? 0, $1.newLine ?? 0) }
        } ?? 0
    }
}

private func pad(_ number: Int?, _ width: Int) -> String {
    let text = number.map(String.init) ?? ""
    return String(repeating: " ", count: max(0, width - text.count)) + text
}

/// A stray "\r" (CRLF files) or other line separator would split one diff row into two
/// in the text view and break the row index, so they're shown as visible symbols instead.
private func displayText(_ line: DiffLine) -> String {
    guard line.text.contains(where: \.isNewline) else { return line.text }
    return String(line.text.map { $0.isNewline ? "␤" : $0 })
}

/// The deleted and added lines that are edits of one another: a run of deletions straight after
/// an equal run of additions, paired in order, as GitHub pairs them. Indices are into `lines`.
private func modifiedPairs(_ lines: [DiffLine]) -> [(old: Int, new: Int)] {
    var pairs: [(old: Int, new: Int)] = []
    var index = 0
    while index < lines.count {
        let deletions = index
        while index < lines.count, lines[index].isDeletion { index += 1 }
        let additions = index
        while index < lines.count, lines[index].isAddition { index += 1 }
        if additions - deletions == index - additions {
            pairs += (0..<(additions - deletions)).map { (deletions + $0, additions + $0) }
        }
        if index == deletions { index += 1 }
    }
    return pairs
}

/// The UTF-16 ranges of the words that differ between two versions of a line, or nil when the
/// lines are too long to compare cheaply or share too little for word changes to mean much.
private func changedWords(_ old: String, _ new: String) -> (old: [NSRange], new: [NSRange])? {
    let oldUnits = Array(old.utf16)
    let newUnits = Array(new.utf16)
    guard oldUnits != newUnits, oldUnits.count <= 1000, newUnits.count <= 1000 else { return nil }
    let oldTokens = tokens(in: oldUnits)
    let newTokens = tokens(in: newUnits)
    guard oldTokens.count <= 300, newTokens.count <= 300 else { return nil }

    let difference = newTokens.map { newUnits[$0] }.difference(from: oldTokens.map { oldUnits[$0] })
    var oldChanged = [Bool](repeating: false, count: oldTokens.count)
    var newChanged = [Bool](repeating: false, count: newTokens.count)
    for change in difference {
        switch change {
        case .remove(let offset, _, _): oldChanged[offset] = true
        case .insert(let offset, _, _): newChanged[offset] = true
        }
    }

    // Similarity counts words and punctuation, not whitespace, which most lines share plenty of.
    let oldWords = oldTokens.indices.filter { !isSpace(oldUnits[oldTokens[$0].lowerBound]) }
    let newWords = newTokens.indices.filter { !isSpace(newUnits[newTokens[$0].lowerBound]) }
    let common = oldWords.count { !oldChanged[$0] }
    guard common > 0, 20 * common >= 3 * (oldWords.count + newWords.count) else { return nil }
    return (changedRanges(oldTokens, oldChanged, oldUnits), changedRanges(newTokens, newChanged, newUnits))
}

/// Joins changed tokens into ranges, bridging single runs of whitespace between them. Changed
/// whitespace alone isn't emphasised: realigned columns would light up as blank blocks.
private func changedRanges(_ tokens: [Range<Int>], _ changed: [Bool], _ units: [UInt16]) -> [NSRange] {
    var ranges: [NSRange] = []
    var index = 0
    while index < tokens.count {
        guard changed[index], !isSpace(units[tokens[index].lowerBound]) else {
            index += 1
            continue
        }
        var end = index
        while end + 1 < tokens.count {
            if changed[end + 1] {
                end += 1
            } else if end + 2 < tokens.count, changed[end + 2], isSpace(units[tokens[end + 1].lowerBound]) {
                end += 2
            } else {
                break
            }
        }
        while isSpace(units[tokens[end].lowerBound]) { end -= 1 }
        ranges.append(NSRange(location: tokens[index].lowerBound, length: tokens[end].upperBound - tokens[index].lowerBound))
        index = end + 1
    }
    return ranges
}

/// Splits a line into words, runs of whitespace, and single punctuation characters.
private func tokens(in units: [UInt16]) -> [Range<Int>] {
    var result: [Range<Int>] = []
    var start = 0
    while start < units.count {
        let kind = tokenKind(units[start])
        var end = start + 1
        if kind != .punctuation {
            while end < units.count, tokenKind(units[end]) == kind { end += 1 }
        }
        result.append(start..<end)
        start = end
    }
    return result
}

private enum TokenKind { case word, space, punctuation }

private func tokenKind(_ unit: UInt16) -> TokenKind {
    switch unit {
    case 0x20, 0x09: .space
    // ASCII letters, digits and underscore; anything non-ASCII counts as part of a word.
    case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x5F, 0x80...: .word
    default: .punctuation
    }
}

private func isSpace(_ unit: UInt16) -> Bool { tokenKind(unit) == .space }
