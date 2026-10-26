import AppKit

/// Where a review comment would attach, in GitHub's terms: RIGHT is the new file, LEFT the old.
public struct DiffAnchor: Sendable, Hashable, CustomStringConvertible {
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
    /// Empty space held for a view laid over the text, such as a review thread.
    case block
}

/// Space in a diff for a view laid over it, such as a review thread under the line it's on.
public struct DiffBlock: Sendable, Equatable {
    public enum Placement: Sendable, Equatable {
        /// Under the row of a line, by its number on one side; LEFT matches a deleted line or
        /// an unchanged one by its old number. A line not in the diff is placed at the end.
        case after(side: DiffAnchor.Side, line: Int)
        /// After the last row.
        case end
    }

    public var id: String
    public var placement: Placement
    public var height: CGFloat

    public init(id: String, placement: Placement, height: CGFloat) {
        self.id = id
        self.placement = placement
        self.height = height
    }
}

public extension NSAttributedString.Key {
    static let diffRowKind = NSAttributedString.Key("Loupe.diffRowKind")
    /// Marks gutter text (line numbers and the +/- marker) so copying a selection yields plain code.
    static let diffGutter = NSAttributedString.Key("Loupe.diffGutter")
    /// The width of the gutter's tinted columns, measured from the start of the line.
    static let diffGutterWidth = NSAttributedString.Key("Loupe.diffGutterWidth")
    /// Marks the words that changed within a modified line, for a stronger tint than the row's.
    static let diffEmphasis = NSAttributedString.Key("Loupe.diffEmphasis")
    /// Marks a control in a hunk header's gutter that reveals more of the file, holding the
    /// `ContextExpansion` it asks for.
    static let diffExpansion = NSAttributedString.Key("Loupe.diffExpansion")
    /// Marks a row held for a `DiffBlock`, holding its id.
    static let diffBlock = NSAttributedString.Key("Loupe.diffBlock")
}

/// One file's diff as a single attributed string, with a gutter of old/new line numbers.
public struct RenderedDiff {
    public let text: NSAttributedString
    /// UTF-16 offset where each row starts, ascending.
    public let rowStarts: [Int]
    /// The anchor for each row; nil for hunk headers.
    public let rowAnchors: [DiffAnchor?]
    /// The row of each hunk's header, in order.
    public let hunkRows: [Int]
    /// The row after the last hunk that reveals more of the file, when there's more to reveal.
    public let trailingRow: Int?
    /// The file's code, ready to highlight; nil when its language isn't known.
    public let syntax: SyntaxPlan?
    /// The row held for each block, by the block's id.
    public let blockRows: [String: Int]

    /// With `expandable`, hunk headers carry controls that reveal the unchanged lines around
    /// them, as GitHub's expand arrows do. Each of `blocks` gets an empty row of its height,
    /// left out of copies, for a view to be laid over.
    /// The code's size, unless a size is given.
    public static let fontSize: CGFloat = 13

    public init(file: FileDiff, fontSize: CGFloat = RenderedDiff.fontSize, expandable: ExpandableContext? = nil, blocks: [DiffBlock] = []) {
        let width = max(3, String(file.maxLineNumber).count)
        // Two right-aligned numbers and the marker, two spaces apart, then a tab out to the code.
        let style = Style(fontSize: fontSize, gutterColumns: width * 2 + 5)
        let out = NSMutableString()
        var rows: [(start: Int, length: Int, gutter: Int, kind: RowKind)] = []
        var anchors: [DiffAnchor?] = []
        var hunkRows: [Int] = []
        var controls: [(range: NSRange, control: ExpansionControl)] = []
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

        func addHeaderRow(body: String, controls offered: [ExpansionControl]) {
            var offset = out.length
            for control in offered {
                let length = (control.label as NSString).length
                controls.append((NSRange(location: offset, length: length), control))
                offset += length
            }
            addRow(gutter: offered.map(\.label).joined() + "\t", body: body, kind: .hunkHeader, anchor: nil)
        }

        var unplaced = BlockQueue(blocks)
        var blockRows: [String: Int] = [:]
        var blockHeights: [(range: NSRange, id: String, height: CGFloat)] = []
        // The whole row, newline included, counts as gutter so a copy leaves it out entirely.
        func addBlockRow(_ block: DiffBlock) {
            blockRows[block.id] = rows.count
            let start = out.length
            out.append(" \n")
            rows.append((start, 2, 2, .block))
            anchors.append(nil)
            blockHeights.append((NSRange(location: start, length: 2), block.id, block.height))
        }

        var emphasis: [NSRange] = []

        for (index, hunk) in file.hunks.enumerated() {
            hunkRows.append(rows.count)
            addHeaderRow(body: hunk.header, controls: expandable == nil ? [] : ExpansionControl.above(hunk: index, in: file))
            // Blocks can come between lines, so each line's row is kept to pair modified lines.
            var lineRows: [Int] = []
            let enclosing = syntax == nil ? nil : enclosingLine(of: hunk)
            var newSide = SyntaxPlan.Side(context: enclosing)
            var oldSide = SyntaxPlan.Side(context: enclosing)
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
                lineRows.append(rows.count - 1)
                if syntax != nil, let row = rows.last {
                    let code = (target: row.start + row.gutter, length: row.length - row.gutter - 1)
                    if line.newLine != nil { newSide.append(line.text, mappedTo: code.target, length: code.length) }
                    if line.oldLine != nil { oldSide.append(line.text, mappedTo: line.isDeletion ? code.target : nil, length: code.length) }
                }
                for block in unplaced.take(after: line) { addBlockRow(block) }
            }
            syntax?.sides += [newSide, oldSide]
            for (old, new) in modifiedPairs(hunk.lines) {
                let oldRow = rows[lineRows[old]]
                let newRow = rows[lineRows[new]]
                guard let changed = changedWords(displayText(hunk.lines[old]), displayText(hunk.lines[new]), ignoringWhitespace: file.ignoresWhitespace) else { continue }
                emphasis += changed.old.map { NSRange(location: oldRow.start + oldRow.gutter + $0.location, length: $0.length) }
                emphasis += changed.new.map { NSRange(location: newRow.start + newRow.gutter + $0.location, length: $0.length) }
            }
        }

        var trailingRow: Int?
        if let lineCount = expandable?.newLineCount, let below = ExpansionControl.belowLastHunk(of: file, newLineCount: lineCount) {
            trailingRow = rows.count
            addHeaderRow(body: "", controls: [below])
        }
        for block in unplaced.remaining { addBlockRow(block) }

        let attributed = NSMutableAttributedString(string: out as String, attributes: style.base)
        attributed.beginEditing()
        for row in rows {
            let full = NSRange(location: row.start, length: row.length)
            attributed.addAttribute(.diffRowKind, value: row.kind.rawValue, range: full)
            attributed.addAttributes(style.gutter, range: NSRange(location: row.start, length: row.gutter))
            if row.kind == .addition || row.kind == .deletion {
                // The marker, just before the gutter's closing tab, reads stronger than the numbers.
                attributed.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: row.start + row.gutter - 2, length: 1))
            }
            if row.kind == .hunkHeader {
                // The line ranges are muted; the function context after them stays the text colour.
                let header = (out.substring(with: NSRange(location: row.start + row.gutter, length: row.length - row.gutter)) as NSString)
                let close = header.range(of: "@@", range: NSRange(location: min(2, header.length), length: max(0, header.length - 2)))
                let ranges = close.location == NSNotFound ? header.length : NSMaxRange(close)
                attributed.addAttributes(style.hunkHeader, range: NSRange(location: row.start + row.gutter, length: ranges))
            }
        }
        for range in emphasis {
            attributed.addAttribute(.diffEmphasis, value: true, range: range)
        }
        for (range, control) in controls {
            attributed.addAttributes(style.control, range: range)
            attributed.addAttributes([.diffExpansion: control.expansion, .toolTip: control.help, .cursor: NSCursor.pointingHand], range: range)
        }
        for block in blockHeights {
            attributed.addAttributes([.paragraphStyle: Self.blockParagraphStyle(height: block.height), .diffBlock: block.id], range: block.range)
        }
        attributed.endEditing()

        text = attributed
        self.syntax = syntax
        rowStarts = rows.map(\.start)
        rowAnchors = anchors
        self.hunkRows = hunkRows
        self.trailingRow = trailingRow
        self.blockRows = blockRows
    }

    /// A block's row is one line exactly as tall as the block.
    static func blockParagraphStyle(height: CGFloat) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = max(1, height)
        paragraph.maximumLineHeight = max(1, height)
        return paragraph
    }

    /// The UTF-16 range of a block's row, newline included.
    public func range(ofBlock id: String) -> NSRange? {
        guard let row = blockRows[id] else { return nil }
        let end = row + 1 < rowStarts.count ? rowStarts[row + 1] : text.length
        return NSRange(location: rowStarts[row], length: end - rowStarts[row])
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

    /// What the expand control at a UTF-16 character offset reveals, if one is there.
    public func expansion(at characterIndex: Int) -> ContextExpansion? {
        guard characterIndex >= 0, characterIndex < text.length else { return nil }
        return text.attribute(.diffExpansion, at: characterIndex, effectiveRange: nil) as? ContextExpansion
    }
}

public extension RowKind {
    var background: NSColor? {
        switch self {
        case .context, .block: nil
        case .addition: DiffColors.additionBackground
        case .deletion: DiffColors.deletionBackground
        case .hunkHeader: DiffColors.hunkHeaderBackground
        }
    }

    /// The gutter's tint, a shade darker than the row's so the numbers read as separate from the code.
    var gutterBackground: NSColor? {
        switch self {
        case .context, .block: nil
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
        case .context, .hunkHeader, .block: nil
        }
    }
}

private struct Style {
    let base: [NSAttributedString.Key: Any]
    let gutter: [NSAttributedString.Key: Any]
    let hunkHeader: [NSAttributedString.Key: Any]
    let control: [NSAttributedString.Key: Any]

    init(fontSize: CGFloat, gutterColumns: Int) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let digit = ("0" as NSString).size(withAttributes: [.font: font]).width
        // The tint runs a little past the marker; the code starts a little past the tint.
        let gutterWidth = digit * CGFloat(gutterColumns) + (fontSize / 3).rounded()
        let codeStart = gutterWidth + (fontSize * 2 / 3).rounded()
        let paragraph = NSMutableParagraphStyle()
        // Rows are five thirds of the font size, as GitHub's 20pt at 12pt, with the extra space
        // split above and below the text.
        let natural = ceil(font.ascender - font.descender + font.leading)
        let extra = max(0, (fontSize * 5 / 3).rounded() - natural)
        paragraph.minimumLineHeight = natural + (extra / 2).rounded(.down)
        paragraph.maximumLineHeight = paragraph.minimumLineHeight
        paragraph.lineSpacing = extra - (extra / 2).rounded(.down)
        // The gutter's tab lands on the code column; wrapped lines hang two columns past it, so a
        // continuation reads as one, and tabs in the code step four columns from the column.
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = codeStart + digit * 2
        paragraph.tabStops = (0..<32).map { NSTextTab(textAlignment: .left, location: codeStart + digit * 4 * CGFloat($0)) }
        paragraph.defaultTabInterval = digit * 4
        base = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph, .diffGutterWidth: gutterWidth]
        gutter = [.foregroundColor: NSColor.tertiaryLabelColor, .diffGutter: true]
        hunkHeader = [.foregroundColor: NSColor.secondaryLabelColor]
        control = [.foregroundColor: NSColor.linkColor, .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)]
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

/// A clickable arrow in a hunk header's gutter, padded either side to make a wider target.
private struct ExpansionControl {
    let glyph: String
    let expansion: ContextExpansion
    let help: String

    var label: String { " \(glyph) " }

    /// Above the first hunk, up; between hunks, one both-ways arrow when the whole gap is a
    /// step or less, else down from the hunk before and up from this one, as on GitHub.
    static func above(hunk index: Int, in file: FileDiff) -> [ExpansionControl] {
        let hidden = file.hiddenLines(above: index)
        let step = ContextExpansion.step
        guard hidden > 0 else { return [] }
        let up = ExpansionControl(glyph: "↑", expansion: ContextExpansion(hunk: index, direction: .above), help: "Show \(step) more lines above")
        if index == 0 { return [up] }
        if hidden <= step {
            let help = hidden == 1 ? "Show the hidden line" : "Show all \(hidden) hidden lines"
            return [ExpansionControl(glyph: "↕", expansion: ContextExpansion(hunk: index, direction: .above, lines: nil), help: help)]
        }
        return [ExpansionControl(glyph: "↓", expansion: ContextExpansion(hunk: index - 1, direction: .below), help: "Show \(step) more lines below"), up]
    }

    static func belowLastHunk(of file: FileDiff, newLineCount: Int) -> ExpansionControl? {
        guard file.hiddenLinesAfterLastHunk(newLineCount: newLineCount) > 0 else { return nil }
        return ExpansionControl(glyph: "↓", expansion: ContextExpansion(hunk: file.hunks.count - 1, direction: .below), help: "Show \(ContextExpansion.step) more lines below")
    }
}

/// The blocks still to place, handed out under the first line each matches.
private struct BlockQueue {
    private var right: [Int: [DiffBlock]] = [:]
    private var left: [Int: [DiffBlock]] = [:]
    private var order: [DiffBlock]
    private var placed: Set<String> = []

    init(_ blocks: [DiffBlock]) {
        order = blocks
        for block in blocks {
            guard case let .after(side, line) = block.placement else { continue }
            switch side {
            case .right: right[line, default: []].append(block)
            case .left: left[line, default: []].append(block)
            }
        }
    }

    /// The blocks to go under `line`: those on its new number, then those on its old number.
    mutating func take(after line: DiffLine) -> [DiffBlock] {
        var taken: [DiffBlock] = []
        if let new = line.newLine, let blocks = right.removeValue(forKey: new) { taken += blocks }
        if let old = line.oldLine, let blocks = left.removeValue(forKey: old) { taken += blocks }
        placed.formUnion(taken.map(\.id))
        return taken
    }

    /// Those for the end and those whose line wasn't found, in the order given.
    var remaining: [DiffBlock] {
        order.filter { !placed.contains($0.id) }
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
/// `ignoringWhitespace`, a change that only splits or joins words with whitespace isn't one.
private func changedWords(_ old: String, _ new: String, ignoringWhitespace: Bool) -> (old: [NSRange], new: [NSRange])? {
    let oldUnits = Array(old.utf16)
    let newUnits = Array(new.utf16)
    guard oldUnits != newUnits, oldUnits.count <= 1000, newUnits.count <= 1000 else { return nil }
    let oldTokens = tokens(in: oldUnits)
    let newTokens = tokens(in: newUnits)
    guard oldTokens.count <= 300, newTokens.count <= 300 else { return nil }

    // Ignoring whitespace, runs of it aren't compared at all, so they can't skew the pairing.
    let oldCompared = oldTokens.indices.filter { !ignoringWhitespace || !isSpace(oldUnits[oldTokens[$0].lowerBound]) }
    let newCompared = newTokens.indices.filter { !ignoringWhitespace || !isSpace(newUnits[newTokens[$0].lowerBound]) }
    let difference = newCompared.map { newUnits[newTokens[$0]] }.difference(from: oldCompared.map { oldUnits[oldTokens[$0]] })
    var oldChanged = [Bool](repeating: false, count: oldTokens.count)
    var newChanged = [Bool](repeating: false, count: newTokens.count)
    for change in difference {
        switch change {
        case .remove(let offset, _, _): oldChanged[oldCompared[offset]] = true
        case .insert(let offset, _, _): newChanged[newCompared[offset]] = true
        }
    }
    if ignoringWhitespace {
        unmarkWhitespaceChanges(old: (oldTokens, oldUnits, oldCompared), new: (newTokens, newUnits, newCompared), &oldChanged, &newChanged)
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

/// Unmarks each replacement that only moves whitespace, such as `foo bar` for `foobar`. A
/// replacement is a run of changed tokens on each side between the same unchanged ones, which
/// the difference of the `compared` tokens keeps in order.
private func unmarkWhitespaceChanges(old: (tokens: [Range<Int>], units: [UInt16], compared: [Int]), new: (tokens: [Range<Int>], units: [UInt16], compared: [Int]), _ oldChanged: inout [Bool], _ newChanged: inout [Bool]) {
    func text(_ side: (tokens: [Range<Int>], units: [UInt16], compared: [Int]), _ run: ArraySlice<Int>) -> [UInt16] {
        run.flatMap { side.units[side.tokens[$0]] }
    }
    var oldIndex = 0
    var newIndex = 0
    while oldIndex < old.compared.count || newIndex < new.compared.count {
        let oldStart = oldIndex
        while oldIndex < old.compared.count, oldChanged[old.compared[oldIndex]] { oldIndex += 1 }
        let newStart = newIndex
        while newIndex < new.compared.count, newChanged[new.compared[newIndex]] { newIndex += 1 }
        let oldRun = old.compared[oldStart..<oldIndex]
        let newRun = new.compared[newStart..<newIndex]
        if text(old, oldRun) == text(new, newRun) {
            for index in oldRun { oldChanged[index] = false }
            for index in newRun { newChanged[index] = false }
        }
        // Past the unchanged token the two sides share.
        oldIndex += 1
        newIndex += 1
    }
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

/// The line git names in the hunk header as the one enclosing the hunk, unless the hunk
/// already shows it, as once the lines above it are revealed, or git cut it short: it keeps
/// 80 bytes of the line, less any space left at the cut, and half a signature misleads.
private func enclosingLine(of hunk: Hunk) -> String? {
    let heading = String(hunk.section.dropFirst())
    guard !heading.trimmingCharacters(in: .whitespaces).isEmpty, heading.utf8.count < 79,
          !hunk.lines.contains(where: { $0.text.hasPrefix(heading) })
    else { return nil }
    return heading
}
