import AppKit
import LoupeModel

/// A plan laid out for review: a row for each resource change, saying what will happen to it and
/// why, that expands to its attributes' changes, then the "Plan:" line and the outputs' changes.
/// Coloured by kind with the diff's syntax palette, and Terraform's symbols and actions in its
/// add, destroy and change colours.
public struct TerraformPlanOutline {
    public enum Action: Sendable, Equatable {
        case none, create, delete, update, replace, read
    }

    public struct Resource: Identifiable {
        /// The address, and the deposed object's key for a deposed one.
        public let id: String
        public let action: Action
        /// The row: what will happen, why, and what forces a replacement, each line ended.
        public let header: NSAttributedString
        /// The attributes' changes, then a blank line.
        public let body: NSAttributedString

        /// The row's text on one line, without its symbol, as VoiceOver reads it.
        public var title: String {
            header.string.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .enumerated().map { $0.offset == 0 ? String($0.element.drop { !$0.isLetter && !$0.isNumber }) : $0.element }
                .joined(separator: ", ")
        }
    }

    public let resources: [Resource]
    /// The "Plan:" line and the outputs' changes, or that there's nothing to do.
    public let trailer: NSAttributedString

    public init(_ plan: TerraformPlan, fontSize: CGFloat = 12) {
        resources = TerraformPlanText.shownResources(plan).map { resource in
            let header = attributed(TerraformPlanText.row(resource), fontSize: fontSize)
            spaceOut(header)
            return Resource(
                id: resource.address + (resource.deposed.map { " (deposed object \($0))" } ?? ""),
                action: TerraformPlanText.action(resource),
                header: header,
                body: attributed(TerraformPlanText.block(resource) + [[]], fontSize: fontSize)
            )
        }
        let trailer = TerraformPlanText.trailer(plan)
        self.trailer = attributed(resources.isEmpty ? trailer : [[]] + trailer, fontSize: fontSize)
    }

    /// The text with every resource expanded, which ⌘F searches.
    public var fullText: String {
        shown(expanded: Set(resources.map(\.id))).text.string
    }

    /// The text with only `expanded`'s resources expanded, and where each piece of it lies in
    /// both that and the full text.
    public func shown(expanded: Set<String>) -> Shown {
        let text = NSMutableAttributedString()
        var pieces: [Shown.Piece] = []
        var full = 0
        func add(_ piece: NSAttributedString, resource: String?, isHeader: Bool, isShown: Bool) {
            let shownRange = NSRange(location: text.length, length: isShown ? piece.length : 0)
            pieces.append(Shown.Piece(resource: resource, isHeader: isHeader, full: NSRange(location: full, length: piece.length), shown: isShown ? shownRange : nil))
            if isShown { text.append(piece) }
            full += piece.length
        }
        for resource in resources {
            add(resource.header, resource: resource.id, isHeader: true, isShown: true)
            add(resource.body, resource: resource.id, isHeader: false, isShown: expanded.contains(resource.id))
        }
        add(trailer, resource: nil, isHeader: false, isShown: true)
        return Shown(text: text, pieces: pieces)
    }

    /// The outline's text with some resources expanded.
    public struct Shown {
        public let text: NSAttributedString
        let pieces: [Piece]

        struct Piece {
            let resource: String?
            let isHeader: Bool
            let full: NSRange
            let shown: NSRange?
        }

        /// Each resource's row, in order, where it is in `text`.
        public var rows: [(id: String, range: NSRange)] {
            pieces.compactMap { piece in
                guard piece.isHeader, let id = piece.resource, let shown = piece.shown else { return nil }
                return (id, shown)
            }
        }

        /// The resource whose row or expanded changes hold `location` in `text`.
        public func resource(at location: Int) -> String? {
            pieces.first { $0.shown.map { NSLocationInRange(location, $0) || (location == NSMaxRange($0) && $0.length == 0) } == true }?.resource
        }

        /// Where a range of the full text is shown, or nil if any of it is in a collapsed
        /// resource.
        public func shownRange(forFull range: NSRange) -> NSRange? {
            guard let start = shownLocation(forFull: range.location, isEnd: false),
                  let end = shownLocation(forFull: NSMaxRange(range), isEnd: true) else { return nil }
            return NSRange(location: start, length: max(0, end - start))
        }

        /// Where a range of `text` is in the full text.
        public func fullRange(forShown range: NSRange) -> NSRange {
            let start = fullLocation(forShown: range.location, isEnd: false)
            return NSRange(location: start, length: max(0, fullLocation(forShown: NSMaxRange(range), isEnd: range.length > 0) - start))
        }

        /// The collapsed resources holding any of a range of the full text, which must be
        /// expanded to show it.
        public func collapsedResources(holding range: NSRange) -> Set<String> {
            Set(pieces.filter { piece in
                piece.shown == nil && (NSIntersectionRange(piece.full, range).length > 0 || (range.length == 0 && NSLocationInRange(range.location, piece.full)))
            }.compactMap(\.resource))
        }

        private func shownLocation(forFull location: Int, isEnd: Bool) -> Int? {
            for piece in pieces {
                let inside = isEnd ? location > piece.full.location && location <= NSMaxRange(piece.full) : NSLocationInRange(location, piece.full)
                guard inside else { continue }
                guard let shown = piece.shown else { return nil }
                return shown.location + location - piece.full.location
            }
            return location == 0 ? 0 : text.length
        }

        /// A range's end maps to the end of the piece it ends in, not past any collapsed piece
        /// after it.
        private func fullLocation(forShown location: Int, isEnd: Bool) -> Int {
            for piece in pieces {
                guard let shown = piece.shown, shown.length > 0 else { continue }
                let inside = isEnd ? location > shown.location && location <= NSMaxRange(shown) : NSLocationInRange(location, shown)
                if inside { return piece.full.location + location - shown.location }
            }
            return location == 0 ? 0 : pieces.last.map { NSMaxRange($0.full) } ?? 0
        }
    }
}

/// Lines of runs as text, each ended, coloured by what each run is.
private func attributed(_ lines: [[Run]], fontSize: CGFloat) -> NSMutableAttributedString {
    let text = NSMutableAttributedString()
    let regular = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    let bold = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
    let italic = NSFontManager.shared.convert(regular, toHaveTrait: .italicFontMask)
    for line in lines {
        for run in line {
            let style = Style(run.role)
            text.append(NSAttributedString(string: run.text, attributes: [
                .font: style.isBold ? bold : style.isItalic ? italic : regular,
                .foregroundColor: style.color,
            ]))
        }
        text.append(NSAttributedString(string: "\n", attributes: [.font: regular, .foregroundColor: NSColor.textColor]))
    }
    return text
}

/// How each kind of run is drawn: the diff's syntax palette for values, Terraform's colours for
/// what will happen, and replacements in the destroy colour, as they destroy.
private struct Style {
    var color: NSColor = .textColor
    var isBold = false
    var isItalic = false

    init(_ role: Run.Role) {
        switch role {
        case .plain, .attribute: break
        case .heading, .address: isBold = true
        case .noChanges: color = DiffColors.successText; isBold = true
        case .comment: color = DiffColors.syntaxComment
        case .forcesReplacement: color = DiffColors.dangerText; isBold = true
        case .unchanged: color = .secondaryLabelColor
        case .string: color = DiffColors.syntaxString
        case .constant: color = DiffColors.syntaxConstant
        case .placeholder: color = DiffColors.syntaxComment; isItalic = true
        case .arrow: color = DiffColors.attentionText; isBold = true
        // Purple rather than the palette's red for keywords, as red here means destroying.
        case .keyword, .function: color = DiffColors.syntaxEntity
        case let .action(action):
            color = actionColor(action)
            isBold = action == .delete || action == .replace
        case let .symbol(action):
            color = actionColor(action)
            isBold = true
        }
    }
}

private func actionColor(_ action: TerraformPlanOutline.Action) -> NSColor {
    switch action {
    case .create: DiffColors.successText
    case .delete, .replace: DiffColors.dangerText
    case .update: DiffColors.attentionText
    case .read: DiffColors.syntaxConstant
    case .none: .secondaryLabelColor
    }
}

/// Space above a row's first line and below its last, inside the band drawn behind it.
private func spaceOut(_ row: NSMutableAttributedString) {
    let string = row.string as NSString
    let first = string.paragraphRange(for: NSRange(location: 0, length: 0))
    let last = string.paragraphRange(for: NSRange(location: max(0, string.length - 1), length: 0))
    let top = NSMutableParagraphStyle()
    top.paragraphSpacingBefore = 4
    if first == last { top.paragraphSpacing = 4 }
    row.addAttribute(.paragraphStyle, value: top, range: first)
    if first != last {
        let bottom = NSMutableParagraphStyle()
        bottom.paragraphSpacing = 4
        row.addAttribute(.paragraphStyle, value: bottom, range: last)
    }
}
