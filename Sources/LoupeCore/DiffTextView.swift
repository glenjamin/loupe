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
    public var wrapsLines = true {
        didSet { if wrapsLines != oldValue { applyWrapping() } }
    }

    /// TextKit 1 for its line-fragment APIs, used to paint row backgrounds across the whole width;
    /// non-contiguous layout keeps very long diffs from being laid out in full up front.
    public static func make() -> DiffTextView {
        let storage = NSTextStorage()
        let layout = RowBackgroundLayoutManager()
        layout.allowsNonContiguousLayout = true
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 10
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
        commentButton.frame = NSRect(x: textContainerOrigin.x + 2, y: fragment.minY + textContainerOrigin.y + (fragment.height - size.height) / 2, width: size.width, height: size.height)
        hoveredAnchor = anchor
        commentButton.toolTip = "Comment on line \(anchor.line) (or middle-click the row)"
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
        self.rendered = rendered
        shownCount += 1
        if let textStorage {
            layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: textStorage.length))
        }
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
        super.mouseDown(with: event)
        // super runs the selection-tracking loop, so a drag has finished by here; only a plain click reports.
        guard selectedRange().length == 0, event.clickCount == 1, let rendered else { return }
        let index = characterIndexForInsertion(at: point)
        if let anchor = rendered.anchor(at: min(index, rendered.text.length - 1)) {
            onAnchorClick?(anchor)
        }
    }

    /// A middle click on a row that takes comments starts one, as its "+" does, so a reviewer
    /// needn't aim for the "+" at the row's edge.
    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, let (_, anchor) = commentableRow(at: convert(event.locationInWindow, from: nil)) else {
            return super.otherMouseDown(with: event)
        }
        onComment?(anchor)
    }

    public override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let textStorage else { return super.writeSelection(to: pboard, type: type) }
        let text = selectedRanges.map(\.rangeValue).map { withoutGutter(textStorage, in: $0) }.joined(separator: "\n")
        return pboard.setString(text, forType: .string)
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
        if wrapsLines {
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

/// Paints each row's background across the whole visible width, with its gutter a shade darker.
/// Done here rather than in the text view's drawBackground(in:) because this only sees glyphs
/// already laid out for drawing; mapping a rect to glyphs from the view forces layout of the whole
/// file above it. The selection is drawn after, so it shows over the tints.
private final class RowBackgroundLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        if let textStorage, let clip = NSGraphicsContext.current?.cgContext.boundingBoxOfClipPath {
            enumerateLineFragments(forGlyphRange: glyphsToShow) { fragment, _, container, glyphRange, _ in
                let charIndex = self.characterIndexForGlyph(at: glyphRange.location)
                guard charIndex < textStorage.length,
                      let raw = textStorage.attribute(.diffRowKind, at: charIndex, effectiveRange: nil) as? Int,
                      let kind = RowKind(rawValue: raw)
                else { return }
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
