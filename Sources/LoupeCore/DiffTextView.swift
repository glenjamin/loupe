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
        return view
    }

    /// Files up to this many rows are highlighted before first paint; larger ones paint plain first.
    public var inlineHighlightRows = 5000

    /// Counts calls to show, so late highlighting for a diff no longer shown is dropped.
    private var shownCount = 0

    public func show(_ rendered: RenderedDiff) {
        self.rendered = rendered
        shownCount += 1
        if let textStorage {
            layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: NSRange(location: 0, length: textStorage.length))
        }
        textStorage?.setAttributedString(rendered.text)
        setSelectedRange(NSRange(location: 0, length: 0))
        scroll(.zero)
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
            }
        }
        super.drawBackground(forGlyphRange: glyphsToShow, at: origin)
    }
}

private func withoutGutter(_ storage: NSTextStorage, in range: NSRange) -> String {
    var pieces = ""
    storage.enumerateAttribute(.diffGutter, in: range) { value, sub, _ in
        if value == nil { pieces += storage.attributedSubstring(from: sub).string }
    }
    return pieces
}
