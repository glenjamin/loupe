import AppKit

/// Read-only, selectable text view for one file's diff. Paints full-width row backgrounds,
/// reports single clicks as anchors or as asking for more context, and leaves the line-number
/// gutter out of copied text.
public final class DiffTextView: NSTextView {
    public var rendered: RenderedDiff?
    public var onAnchorClick: ((DiffAnchor) -> Void)?
    /// Called when a hunk header's expand control is clicked.
    public var onExpand: ((ContextExpansion) -> Void)?
    /// The row to hold still on screen when the clicked expansion arrives, and how far below
    /// the top of the view it was.
    private var heldRow: (row: HeldRow, offset: CGFloat)?
    /// Views laid over the rows held for blocks, by block id.
    private var blockViews: [String: NSView] = [:]
    /// The rows a comment can be started on, by anchor; none when nil.
    public var commentableAnchors: Set<DiffAnchor>? {
        didSet { if commentableAnchors != oldValue { hoveredAnchor = nil } }
    }
    /// Called with the hovered row's anchor when its "+" is clicked.
    public var onComment: ((DiffAnchor) -> Void)?
    /// The quiet "+" in the gutter of the hovered row, as on github.com.
    public let commentButton = CommentButton()
    private var hoveredAnchor: DiffAnchor? {
        didSet { commentButton.isHidden = hoveredAnchor == nil }
    }

    /// Soft-wraps long rows at the view's width; off, rows run on and the view scrolls sideways.
    /// A split diff always wraps, each side within its half.
    public var wrapsLines = true {
        didSet { if wrapsLines != oldValue { applyWrapping() } }
    }
    private var wraps: Bool { wrapsLines || rendered?.layout == .split }
    /// The side a selection being dragged in a split diff began on, which it keeps to.
    private var selectionSide: DiffAnchor.Side?

    /// The space at each end of a line, and of each side of a split row.
    nonisolated static let linePadding: CGFloat = 10

    /// TextKit 1 for its line-fragment APIs, used to paint row backgrounds across the whole width;
    /// non-contiguous layout keeps very long diffs from being laid out in full up front.
    public static func make() -> DiffTextView {
        let storage = NSTextStorage()
        let layout = RowBackgroundLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = SplitTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = linePadding
        layout.addTextContainer(container)

        let view = DiffTextView(frame: .zero, textContainer: container)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = false
        view.usesFindBar = true
        view.isIncrementalSearchingEnabled = true
        view.drawsBackground = true
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 0, height: 4)
        view.isVerticallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.minSize = .zero
        view.applyWrapping()
        view.commentButton.isHidden = true
        view.commentButton.target = view
        view.commentButton.action = #selector(commentClicked)
        view.addSubview(view.commentButton)
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: view))
        return view
    }

    /// Shows the "+" on the row under the pointer when a comment can be started there.
    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        showCommentButton(at: convert(event.locationInWindow, from: nil))
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoveredAnchor = nil
    }

    @objc private func commentClicked() {
        if let hoveredAnchor { onComment?(hoveredAnchor) }
    }

    private func showCommentButton(at point: NSPoint) {
        guard let rendered, let layoutManager, let (row, anchor) = commentableRow(at: point) else {
            return hoveredAnchor = nil
        }
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: rendered.rowStarts[row]), effectiveRange: nil)
        // Over the start of the gutter, a little in from the edge, centred on the row's first line.
        let size = commentButton.intrinsicContentSize
        let sideStart = rendered.rowSides[row] == .right ? (textContainer as? SplitTextContainer)?.splitX ?? 0 : 0
        commentButton.frame = NSRect(x: textContainerOrigin.x + sideStart + 2, y: fragment.minY + textContainerOrigin.y + (fragment.height - size.height) / 2, width: size.width, height: size.height)
        hoveredAnchor = anchor
        commentButton.toolTip = "Comment on line \(anchor.line) (or double-click the row)"
    }

    /// The row under a point, gutter or code, and its anchor, when a comment can be started there.
    private func commentableRow(at point: NSPoint) -> (row: Int, anchor: DiffAnchor)? {
        guard let commentableAnchors, let rendered, let textStorage, textStorage.length > 0 else { return nil }
        let index = min(characterIndexForInsertion(at: point), textStorage.length - 1)
        guard let row = rendered.row(at: index), let anchor = rendered.rowAnchors[row], commentableAnchors.contains(anchor) else { return nil }
        return (row, anchor)
    }

    /// Files up to this many rows are highlighted before first paint; larger ones paint plain first.
    public var inlineHighlightRows = 5000

    /// Counts calls to show, so late highlighting for a diff no longer shown is dropped.
    private var shownCount = 0

    /// Shows a diff from its top or, `keepingPlace`, a new rendering of the same file where the
    /// reader was: the row whose expand control was clicked holds still, else the first code row
    /// in view that's still shown, as when revealed lines are hidden, else the view stays
    /// scrolled as it was.
    public func show(_ rendered: RenderedDiff, keepingPlace: Bool = false) {
        let visible = visibleRect
        let held = keepingPlace ? heldRow ?? visibleCodeRow(keptIn: rendered) : nil
        heldRow = nil
        hoveredAnchor = nil
        let wrapped = wraps
        self.rendered = rendered
        shownCount += 1
        if let textStorage {
            layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: textStorage.length))
        }
        let isSplit = rendered.layout == .split
        (textContainer as? SplitTextContainer)?.isSplit = isSplit
        (layoutManager as? RowBackgroundLayoutManager)?.splitRows.isSplit = isSplit
        if wraps != wrapped { applyWrapping() }
        textStorage?.setAttributedString(rendered.text)
        setSelectedRange(NSRange(location: 0, length: 0))
        if let held, let row = held.row.index(in: rendered), let top = top(ofRow: row) {
            scroll(NSPoint(x: visible.minX, y: max(0, top - held.offset)))
        } else {
            scroll(keepingPlace ? visible.origin : .zero)
        }
        layoutBlocks()
        guard let plan = rendered.syntax else { return }
        if rendered.rowStarts.count <= inlineHighlightRows {
            applyHighlights(plan.runs())
        } else {
            highlightLater(plan)
        }
    }

    /// Colours the shown diff's code. The colours are the layout manager's temporary attributes,
    /// not the text storage's: splitting a large storage's attribute runs costs several times as much.
    public func applyHighlights<Runs: Sequence<SyntaxRun>>(_ runs: Runs) {
        guard let layoutManager else { return }
        for run in runs {
            layoutManager.addTemporaryAttribute(.foregroundColor, value: run.style.color, forCharacterRange: run.range)
        }
    }

    /// Lays `views` over the rows the shown diff holds for blocks, by block id, replacing any
    /// laid there before.
    public func setBlockViews(_ views: [String: NSView]) {
        for (id, view) in blockViews where views[id] !== view {
            view.removeFromSuperview()
        }
        for view in views.values where view.superview !== self {
            addSubview(view)
        }
        blockViews = views
        layoutBlocks()
    }

    /// Makes a block's row as tall as its view now needs, which moves everything below it.
    public func setHeight(_ height: CGFloat, ofBlock id: String) {
        guard let textStorage, let range = rendered?.range(ofBlock: id), NSMaxRange(range) <= textStorage.length else { return }
        let current = textStorage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
        guard current?.minimumLineHeight != max(1, height) else { return }
        textStorage.addAttribute(.paragraphStyle, value: RenderedDiff.blockParagraphStyle(height: height), range: range)
        layoutBlocks()
    }

    /// Places each block's view over its row, across the visible width so it stays in view when
    /// rows run on sideways. Everything above a block is laid out to find where it falls.
    public func layoutBlocks() {
        guard let layoutManager, let rendered, let textStorage else { return }
        let visible = visibleRect.width > 0 ? visibleRect : bounds
        for (id, view) in blockViews {
            guard let range = rendered.range(ofBlock: id), NSMaxRange(range) <= textStorage.length else {
                view.isHidden = true
                continue
            }
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
            let frame = NSRect(x: visible.minX, y: fragment.minY + textContainerOrigin.y, width: visible.width, height: fragment.height)
            view.isHidden = false
            if view.frame != frame { view.frame = frame }
        }
    }

    /// Scrolls a block's row to a third of the way down the view, as github.com puts a linked
    /// comment, with the code it hangs under in view above it. A block too tall for the rest of
    /// the view goes higher so its end shows, though never so high its top doesn't.
    public func scrollToBlock(_ id: String) {
        guard let layoutManager, let rendered, let textStorage, let range = rendered.range(ofBlock: id), NSMaxRange(range) <= textStorage.length else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
        let top = fragment.minY + textContainerOrigin.y
        let visible = visibleRect
        let margin: CGFloat = 40
        let showingEnd = max(top - visible.height / 3, top + fragment.height + margin - visible.height)
        scroll(NSPoint(x: visible.minX, y: max(0, min(showingEnd, top - margin))))
    }

    /// The expand arrows act on the first click, as buttons do, even in a window not yet active.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        guard let event, let rendered, let index = characterIndex(under: convert(event.locationInWindow, from: nil)),
              rendered.expansion(at: index) != nil
        else { return super.acceptsFirstMouse(for: event) }
        return true
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.clickCount == 1, let rendered, let index = characterIndex(under: point), let expansion = rendered.expansion(at: index) {
            hold(rowAt: index, for: expansion, in: rendered)
            onExpand?(expansion)
            return
        }
        // Double-clicking a row that takes comments starts one, as its "+" does, instead of
        // selecting a word; elsewhere a double-click selects as usual.
        if event.clickCount == 2, let (_, anchor) = commentableRow(at: point) {
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
            onComment?(anchor)
            return
        }
        selectionSide = splitSide(at: point)
        super.mouseDown(with: event)
        selectionSide = nil
        // super runs the selection-tracking loop, so a drag has finished by here; only a plain click reports.
        guard selectedRange().length == 0, event.clickCount == 1, let rendered else { return }
        let index = characterIndexForInsertion(at: point)
        if let anchor = rendered.anchor(at: min(index, rendered.text.length - 1)) {
            onAnchorClick?(anchor)
        }
    }

    public override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let textStorage else { return super.writeSelection(to: pboard, type: type) }
        let ranges = selectedRanges.map(\.rangeValue)
        // A split diff's selection kept to one side copies that side's code, a line per row.
        if let rendered, rendered.layout == .split, let whole = union(of: ranges),
           let side = rendered.row(at: whole.location).flatMap({ rendered.rowSides[$0] }) {
            let code = rendered.code(in: whole, onSide: side).map { textStorage.mutableString.substring(with: $0) }
            return pboard.setString(code.joined(separator: "\n"), forType: .string)
        }
        // A split row taken whole gives each side a line.
        let text = ranges.map { withoutGutter(textStorage, in: $0) }.joined(separator: "\n")
            .replacingOccurrences(of: String(utf16CodeUnits: [splitSideSeparator], count: 1), with: "\n")
        return pboard.setString(text, forType: .string)
    }

    /// In a split diff, a selection begun on one side's code keeps to that side's code, as on
    /// github.com, rather than taking in the other side's lines between.
    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        guard let rendered, rendered.layout == .split, let whole = union(of: ranges.map(\.rangeValue)), whole.length > 0,
              let side = selectionSide ?? rendered.row(at: whole.location).flatMap({ rendered.rowSides[$0] })
        else { return super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting) }
        let kept = rendered.code(in: whole, onSide: side).filter { $0.length > 0 }
        let selection = kept.isEmpty ? [NSRange(location: whole.location, length: 0)] : kept
        super.setSelectedRanges(selection.map { NSValue(range: $0) }, affinity: affinity, stillSelecting: stillSelecting)
    }

    /// The side of a split row under a point, or nil off a split row.
    private func splitSide(at point: NSPoint) -> DiffAnchor.Side? {
        guard let rendered, rendered.layout == .split, let container = textContainer as? SplitTextContainer,
              let index = characterIndex(nearest: point), let row = rendered.row(at: index), rendered.rowSides[row] != nil
        else { return nil }
        return point.x - textContainerOrigin.x >= container.splitX ? .right : .left
    }

    /// Large files paint plain first, then take their colours once parsed off the main thread,
    /// top first and in slices so the main thread stays responsive.
    private func highlightLater(_ plan: SyntaxPlan) {
        let shown = shownCount
        Task { [weak self] in
            let runs = await Task.detached(priority: .userInitiated) { plan.runs() }.value
            for start in stride(from: 0, to: runs.count, by: 5000) {
                guard let self, self.shownCount == shown else { return }
                self.applyHighlights(runs[start..<min(start + 5000, runs.count)])
                await Task.yield()
            }
        }
    }

    /// Remembers which row to hold still once the expansion is shown: the clicked control's
    /// own, unless it goes once the gap closes, when the code beside it holds instead.
    private func hold(rowAt index: Int, for expansion: ContextExpansion, in rendered: RenderedDiff) {
        guard let row = rendered.row(at: index), let top = top(ofRow: row) else { return }
        let beside = expansion.direction == .above ? row + 1 : row - 1
        let code = rendered.rowAnchors.indices.contains(beside) ? rendered.rowAnchors[beside] : nil
        let held: HeldRow
        if row == rendered.trailingRow {
            held = .trailing(orElse: code)
        } else if let hunk = rendered.hunkRows.firstIndex(of: row), expansion.lines != nil || code == nil {
            held = .hunkHeader(hunk)
        } else if let code {
            held = .line(code)
        } else {
            return
        }
        heldRow = (held, top - visibleRect.minY)
    }

    /// The first row in view, from the top, whose line is still in `next`, and how far below
    /// the top of the view it is, so rows going above or around it don't move the reader.
    private func visibleCodeRow(keptIn next: RenderedDiff) -> (row: HeldRow, offset: CGFloat)? {
        guard let current = rendered, let textStorage, textStorage.length > 0 else { return nil }
        let visible = visibleRect
        guard let first = characterIndex(nearest: NSPoint(x: visible.minX, y: visible.minY)),
              var row = current.row(at: min(first, textStorage.length - 1))
        else { return nil }
        while let top = top(ofRow: row), top < visible.maxY {
            if let anchor = current.rowAnchors[row], next.rowAnchors.contains(anchor) {
                return (.line(anchor), top - visible.minY)
            }
            row += 1
        }
        return nil
    }

    /// The top of a row in the view. Everything above it is laid out first, as non-contiguous
    /// layout would otherwise only estimate where it falls.
    private func top(ofRow row: Int) -> CGFloat? {
        guard let layoutManager, let rendered, rendered.rowStarts.indices.contains(row) else { return nil }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: rendered.rowStarts[row] + 1))
        let glyph = layoutManager.glyphIndexForCharacter(at: rendered.rowStarts[row])
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + textContainerOrigin.y
    }

    /// The character nearest a point in the view, from the layout alone. Unlike
    /// `characterIndexForInsertion(at:)` it doesn't go through the window, which re-enters
    /// SwiftUI when called while it updates the diff.
    private func characterIndex(nearest point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer)
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    /// The character drawn under a point in the view, if any; unlike the insertion point, this
    /// is never the character beside the one clicked.
    private func characterIndex(under point: NSPoint) -> Int? {
        guard let layoutManager, let textContainer, let textStorage, textStorage.length > 0 else { return nil }
        let inContainer = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let glyph = layoutManager.glyphIndex(for: inContainer, in: textContainer, fractionOfDistanceThroughGlyph: nil)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let bounds = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard (fragment.minY..<fragment.maxY).contains(inContainer.y), (bounds.minX..<bounds.maxX).contains(inContainer.x) else { return nil }
        return layoutManager.characterIndexForGlyph(at: glyph)
    }

    private func applyWrapping() {
        guard let textContainer else { return }
        let unbounded = CGFloat.greatestFiniteMagnitude
        if wraps {
            isHorizontallyResizable = false
            autoresizingMask = [.width]
            if let clip = enclosingScrollView?.contentView {
                setFrameSize(NSSize(width: clip.bounds.width, height: frame.height))
            }
            textContainer.size = NSSize(width: max(0, bounds.width - textContainerInset.width * 2), height: unbounded)
            textContainer.widthTracksTextView = true
        } else {
            textContainer.widthTracksTextView = false
            textContainer.size = NSSize(width: unbounded, height: unbounded)
            isHorizontallyResizable = true
            autoresizingMask = [.width, .height]
        }
    }
}

/// A small accent "+" that starts a comment on the row it's over.
public final class CommentButton: NSButton {
    override init(frame: NSRect) {
        super.init(frame: frame)
        image = NSImage(systemSymbolName: "plus.square.fill", accessibilityDescription: "Add a comment")
        imageScaling = .scaleProportionallyUpOrDown
        isBordered = false
        contentTintColor = .controlAccentColor
        setAccessibilityLabel("Add a comment")
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used in nibs") }

    public override var intrinsicContentSize: NSSize { NSSize(width: 18, height: 18) }

    /// Acts on the first click, as the expand arrows do, even in a window not yet active.
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Paints each row's background across the whole visible width, with its gutter a shade darker;
/// a split row's sides each across their half. Done here rather than in the text view's
/// drawBackground(in:) because this only sees glyphs already laid out for drawing; mapping a rect
/// to glyphs from the view forces layout of the whole file above it. The selection is drawn
/// after, so it shows over the tints.
final class RowBackgroundLayoutManager: NSLayoutManager {
    /// Lays a split row's sides out beside each other.
    let splitRows = SplitRowLayout()

    override init() {
        super.init()
        delegate = splitRows
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used in nibs") }

    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let textStorage, let clip = NSGraphicsContext.current?.cgContext.boundingBoxOfClipPath {
            enumerateLineFragments(forGlyphRange: glyphsToShow) { fragment, _, container, glyphRange, _ in
                let charIndex = self.characterIndexForGlyph(at: glyphRange.location)
                guard charIndex < textStorage.length,
                      let raw = textStorage.attribute(.diffRowKind, at: charIndex, effectiveRange: nil) as? Int,
                      let kind = RowKind(rawValue: raw)
                else { return }
                if let split = container as? SplitTextContainer, split.isSplit,
                   let side = textStorage.attribute(.diffSplitSide, at: charIndex, effectiveRange: nil) as? Int {
                    return self.drawSplitBackground(fragment: fragment, glyphs: glyphRange, kind: kind, side: side, at: charIndex, origin: origin, clip: clip, container: split)
                }
                let row = NSRect(x: clip.minX, y: fragment.minY + origin.y, width: clip.width, height: fragment.height)
                if let color = kind.background {
                    color.setFill()
                    row.fill()
                }
                if let color = kind.gutterBackground,
                   let width = textStorage.attribute(.diffGutterWidth, at: charIndex, effectiveRange: nil) as? CGFloat {
                    let end = origin.x + fragment.minX + container.lineFragmentPadding + width
                    color.setFill()
                    NSRect(x: min(clip.minX, origin.x), y: row.minY, width: end - min(clip.minX, origin.x), height: row.height).fill()
                }
                if let color = kind.emphasisBackground {
                    self.fillEmphasis(in: glyphRange, row: row, origin: origin, container: container, color: color)
                }
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }

    /// TextKit finds the line under a point by its height alone, so on a split row it can pick
    /// the other side's line at that height; the point's own side is searched instead.
    override func glyphIndex(for point: NSPoint, in container: NSTextContainer, fractionOfDistanceThroughGlyph fraction: UnsafeMutablePointer<CGFloat>?) -> Int {
        let glyph = super.glyphIndex(for: point, in: container, fractionOfDistanceThroughGlyph: fraction)
        guard let split = container as? SplitTextContainer, split.isSplit, let textStorage, glyph < numberOfGlyphs else { return glyph }
        let character = characterIndexForGlyph(at: glyph)
        guard character < textStorage.length,
              let side = textStorage.attribute(.diffSplitSide, at: character, effectiveRange: nil) as? Int,
              let row = splitRow(containing: character)
        else { return glyph }
        let wanted = point.x >= split.splitX ? 1 : 0
        guard side != wanted else { return glyph }
        let glyphs = glyphRange(forCharacterRange: wanted == 0 ? row.left : row.right, actualCharacterRange: nil)
        // The side's last line at or above the point.
        var line: (rect: NSRect, glyphs: NSRange)?
        enumerateLineFragments(forGlyphRange: glyphs) { rect, _, _, range, stop in
            if line == nil || rect.minY <= point.y { line = (rect, NSIntersectionRange(range, glyphs)) }
            if rect.maxY > point.y { stop.pointee = true }
        }
        guard let line, line.glyphs.length > 0 else { return glyph }
        // The glyph whose span holds the point, or the line's end past its last.
        for index in line.glyphs.location..<NSMaxRange(line.glyphs) {
            let start = line.rect.minX + location(forGlyphAt: index).x
            let end = index + 1 < NSMaxRange(line.glyphs) ? line.rect.minX + location(forGlyphAt: index + 1).x : line.rect.maxX
            if point.x < end {
                fraction?.pointee = end > start ? min(1, max(0, (point.x - start) / (end - start))) : 0
                return index
            }
        }
        fraction?.pointee = 0
        return NSMaxRange(line.glyphs) - 1
    }

    /// One side of a split row on one line fragment: its tint across its half, its gutter's, the
    /// changed words', and for the right side the rule between the sides and any of the left
    /// side's tint left below its last line, as the right side's lines span the whole row.
    private func drawSplitBackground(fragment: NSRect, glyphs: NSRange, kind: RowKind, side: Int, at character: Int, origin: NSPoint, clip: CGRect, container: SplitTextContainer) {
        guard let textStorage else { return }
        let gutter = textStorage.attribute(.diffGutterWidth, at: character, effectiveRange: nil) as? CGFloat ?? 0
        func fill(side: Int, kind: RowKind, from top: CGFloat, to bottom: CGFloat) {
            let start = side == 0 ? min(clip.minX, origin.x) : origin.x + container.splitX
            let end = side == 0 ? origin.x + container.splitX : max(clip.maxX, origin.x + container.size.width)
            let rect = NSRect(x: start, y: top, width: end - start, height: bottom - top)
            if let color = kind.background {
                color.setFill()
                rect.fill()
            }
            if let color = kind.gutterBackground {
                let sideStart = origin.x + (side == 0 ? 0 : container.splitX)
                color.setFill()
                NSRect(x: start, y: top, width: sideStart + container.lineFragmentPadding + gutter - start, height: rect.height).fill()
            }
        }
        let top = fragment.minY + origin.y
        fill(side: side, kind: kind, from: top, to: fragment.maxY + origin.y)
        if let color = kind.emphasisBackground {
            fillEmphasis(in: glyphs, row: NSRect(x: 0, y: top, width: 0, height: fragment.height), origin: origin, container: container, color: color)
        }
        guard side == 1, let row = splitRow(containing: character) else { return }
        let separator = glyphIndexForCharacter(at: NSMaxRange(row.left) - 1)
        let leftBottom = lineFragmentRect(forGlyphAt: separator, effectiveRange: nil).maxY + origin.y
        if fragment.maxY + origin.y > leftBottom,
           let raw = textStorage.attribute(.diffRowKind, at: row.left.location, effectiveRange: nil) as? Int, let left = RowKind(rawValue: raw) {
            fill(side: 0, kind: left, from: max(top, leftBottom), to: fragment.maxY + origin.y)
        }
        DiffColors.splitDivider.setFill()
        NSRect(x: origin.x + container.splitX - 0.5, y: top, width: 1, height: fragment.height).fill()
    }

    /// Tints the changed words on one line fragment, the full height of the row.
    private func fillEmphasis(in glyphs: NSRange, row: NSRect, origin: NSPoint, container: NSTextContainer, color: NSColor) {
        guard let textStorage else { return }
        let characters = characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        color.setFill()
        textStorage.enumerateAttribute(.diffEmphasis, in: characters) { value, range, _ in
            guard value != nil else { return }
            let bounds = boundingRect(forGlyphRange: glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
            NSRect(x: bounds.minX + origin.x, y: row.minY, width: bounds.width, height: row.height).fill()
        }
    }

    /// The characters of each side of the split row holding `character`: the left's ending in
    /// the separator, the right's in the newline.
    private func splitRow(containing character: Int) -> (left: NSRange, right: NSRange)? {
        textStorage.flatMap { splitRowRanges(in: $0.mutableString, containing: character) }
    }
}

/// Gives each side of a split row its half of the width: the left side's lines the left half,
/// the right side's the right half, each with its own hanging indent. Other rows, and every row
/// of a unified diff, take the whole width.
final class SplitTextContainer: NSTextContainer {
    var isSplit = false

    /// Where the right side starts, from the container's left.
    var splitX: CGFloat { (size.width / 2).rounded(.down) }

    override var isSimpleRectangularTextContainer: Bool { true }

    override func lineFragmentRect(forProposedRect proposedRect: NSRect, at characterIndex: Int, writingDirection baseWritingDirection: NSWritingDirection, remaining remainingRect: UnsafeMutablePointer<NSRect>?) -> NSRect {
        let rect = super.lineFragmentRect(forProposedRect: proposedRect, at: characterIndex, writingDirection: baseWritingDirection, remaining: remainingRect)
        guard isSplit, let storage = layoutManager?.textStorage, characterIndex < storage.length,
              let side = storage.attribute(.diffSplitSide, at: characterIndex, effectiveRange: nil) as? Int
        else { return rect }
        // Split rows have no paragraph indent, as the right side's first line would take it, so
        // continuations are hung here, by starting their fragment that far in.
        let previous = characterIndex > 0 ? storage.mutableString.character(at: characterIndex - 1) : 0x0A
        let startsSide = previous == 0x0A || previous == splitSideSeparator
        let hang = startsSide ? 0 : storage.attribute(.diffHangingIndent, at: characterIndex, effectiveRange: nil) as? CGFloat ?? 0
        let start = (side == 0 ? 0 : splitX) + hang
        let end = side == 0 ? splitX : size.width
        return NSRect(x: start, y: rect.minY, width: max(0, end - start), height: rect.height)
    }
}

/// Lifts a split row's right side up beside its left, which TextKit lays out first as the line
/// above, and stretches the right side's last line to the foot of the taller side, so the next
/// row starts below both.
final class SplitRowLayout: NSObject, NSLayoutManagerDelegate {
    var isSplit = false
    private var rowTop: CGFloat = 0
    private var leftBottom: CGFloat = 0
    private var rightBottom: CGFloat?

    func layoutManager(_ layoutManager: NSLayoutManager, shouldSetLineFragmentRect lineFragmentRect: UnsafeMutablePointer<NSRect>, lineFragmentUsedRect: UnsafeMutablePointer<NSRect>, baselineOffset: UnsafeMutablePointer<CGFloat>, in textContainer: NSTextContainer, forGlyphRange glyphRange: NSRange) -> Bool {
        guard isSplit, let storage = layoutManager.textStorage else { return false }
        let characters = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        guard characters.location < storage.length, characters.length > 0,
              let side = storage.attribute(.diffSplitSide, at: characters.location, effectiveRange: nil) as? Int
        else { return false }
        let text = storage.mutableString
        var rect = lineFragmentRect.pointee
        if side == 0 {
            // A row is a paragraph, and its left side its first lines.
            if characters.location == 0 || text.character(at: characters.location - 1) == 0x0A {
                rowTop = rect.minY
                rightBottom = nil
            }
            leftBottom = rect.maxY
            return false
        }
        let shift = (rightBottom ?? rowTop) - rect.minY
        rect.origin.y += shift
        lineFragmentUsedRect.pointee.origin.y += shift
        if text.character(at: NSMaxRange(characters) - 1) == 0x0A {
            rect.size.height = max(rect.maxY, leftBottom) - rect.minY
        }
        rightBottom = rect.maxY
        lineFragmentRect.pointee = rect
        return true
    }
}

/// The characters of each side of the split row holding `character`, or nil off a split row.
func splitRowRanges(in text: NSString, containing character: Int) -> (left: NSRange, right: NSRange)? {
    let row = text.paragraphRange(for: NSRange(location: character, length: 0))
    let separator = text.range(of: String(utf16CodeUnits: [splitSideSeparator], count: 1), options: .literal, range: row)
    guard separator.location != NSNotFound else { return nil }
    return (NSRange(location: row.location, length: NSMaxRange(separator) - row.location),
            NSRange(location: NSMaxRange(separator), length: NSMaxRange(row) - NSMaxRange(separator)))
}

/// A row identified so it can be found again in a new rendering of the file.
private enum HeldRow {
    case hunkHeader(Int)
    /// The row below the last hunk, or the code above it once the file's end is reached.
    case trailing(orElse: DiffAnchor?)
    case line(DiffAnchor)

    func index(in rendered: RenderedDiff) -> Int? {
        switch self {
        case let .hunkHeader(hunk): rendered.hunkRows.indices.contains(hunk) ? rendered.hunkRows[hunk] : nil
        case let .trailing(code): rendered.trailingRow ?? code.flatMap { rendered.rowAnchors.firstIndex(of: $0) }
        case let .line(code): rendered.rowAnchors.firstIndex(of: code)
        }
    }
}

private func withoutGutter(_ storage: NSTextStorage, in range: NSRange) -> String {
    var pieces = ""
    storage.enumerateAttribute(.diffGutter, in: range) { value, sub, _ in
        if value == nil { pieces += storage.attributedSubstring(from: sub).string }
    }
    return pieces
}

/// The smallest range covering all of `ranges`.
private func union(of ranges: [NSRange]) -> NSRange? {
    guard let first = ranges.first, let last = ranges.last else { return nil }
    return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
}
