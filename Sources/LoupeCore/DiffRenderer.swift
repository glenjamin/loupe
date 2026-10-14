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
        let width = max(4, String(file.maxLineNumber).count)
        // Two numbers, a space between, two before the marker, and the marker itself.
        let style = Style(fontSize: fontSize, gutterColumns: width * 2 + 4)
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

        for hunk in file.hunks {
            addRow(gutter: "", body: hunk.header, kind: .hunkHeader, anchor: nil)
            var newSide = SyntaxPlan.Side()
            var oldSide = SyntaxPlan.Side()
            for line in hunk.lines {
                let numbers = pad(line.oldLine, width) + " " + pad(line.newLine, width) + "  "
                let body = displayText(line)
                switch line.kind {
                case .context(_, let new):
                    addRow(gutter: numbers + " ", body: body, kind: .context, anchor: DiffAnchor(path: file.path, side: .right, line: new))
                case .addition(let new):
                    addRow(gutter: numbers + "+", body: body, kind: .addition, anchor: DiffAnchor(path: file.path, side: .right, line: new))
                case .deletion(let old):
                    addRow(gutter: numbers + "-", body: body, kind: .deletion, anchor: DiffAnchor(path: file.path, side: .left, line: old))
                }
                if syntax != nil, let row = rows.last {
                    let code = (target: row.start + row.gutter, length: row.length - row.gutter - 1)
                    if line.newLine != nil { newSide.append(line.text, mappedTo: code.target, length: code.length) }
                    if line.oldLine != nil { oldSide.append(line.text, mappedTo: line.isDeletion ? code.target : nil, length: code.length) }
                }
            }
            syntax?.sides += [newSide, oldSide]
        }

        let attributed = NSMutableAttributedString(string: out as String, attributes: style.base)
        attributed.beginEditing()
        for row in rows {
            let full = NSRange(location: row.start, length: row.length)
            attributed.addAttribute(.diffRowKind, value: row.kind.rawValue, range: full)
            if row.kind == .hunkHeader {
                attributed.addAttributes(style.hunkHeader, range: full)
            } else if row.gutter > 0 {
                attributed.addAttributes(style.gutter, range: NSRange(location: row.start, length: row.gutter))
            }
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
}

private struct Style {
    let base: [NSAttributedString.Key: Any]
    let gutter: [NSAttributedString.Key: Any]
    let hunkHeader: [NSAttributedString.Key: Any]

    init(fontSize: CGFloat, gutterColumns: Int) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        // Wrapped continuation lines hang under the code rather than under the gutter.
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 0
        paragraph.headIndent = (String(repeating: "0", count: gutterColumns) as NSString).size(withAttributes: [.font: font]).width
        base = [.font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraph]
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
