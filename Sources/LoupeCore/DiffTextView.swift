import AppKit

/// Read-only, selectable text view for one file's diff. Paints full-width row backgrounds,
/// reports single clicks as anchors, and leaves the line-number gutter out of copied text.
public final class DiffTextView: NSTextView {
    public var rendered: RenderedDiff?
    public var onAnchorClick: ((DiffAnchor) -> Void)?

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
        return view
    }

    public func show(_ rendered: RenderedDiff) {
        self.rendered = rendered
        textStorage?.setAttributedString(rendered.text)
        setSelectedRange(NSRange(location: 0, length: 0))
        scroll(.zero)
    }

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        super.mouseDown(with: event)
        // super runs the selection-tracking loop, so a drag has finished by here; only a plain click reports.
        guard selectedRange().length == 0, event.clickCount == 1, let rendered else { return }
        let index = characterIndexForInsertion(at: point)
        if let anchor = rendered.anchor(at: min(index, rendered.text.length - 1)) {
            onAnchorClick?(anchor)
        }
    }

    public override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string, let textStorage else { return super.writeSelection(to: pboard, type: type) }
        let text = selectedRanges.map(\.rangeValue).map { withoutGutter(textStorage, in: $0) }.joined(separator: "\n")
        return pboard.setString(text, forType: .string)
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

/// Paints each row's background across the whole visible width. Done here rather than in the text
/// view's drawBackground(in:) because this only sees glyphs already laid out for drawing; mapping a
/// rect to glyphs from the view forces layout of the whole file above it.
private final class RowBackgroundLayoutManager: NSLayoutManager {
    override func drawBackground(forGlyphRange glyphsToShow: NSRange, at origin: NSPoint) {
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
        guard let textStorage, let clip = NSGraphicsContext.current?.cgContext.boundingBoxOfClipPath else { return }
        enumerateLineFragments(forGlyphRange: glyphsToShow) { fragment, _, _, glyphRange, _ in
            let charIndex = self.characterIndexForGlyph(at: glyphRange.location)
            guard charIndex < textStorage.length,
                  let raw = textStorage.attribute(.diffRowKind, at: charIndex, effectiveRange: nil) as? Int,
                  let color = RowKind(rawValue: raw)?.background
            else { return }
            color.setFill()
            NSRect(x: clip.minX, y: fragment.minY + origin.y, width: clip.width, height: fragment.height).fill()
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
