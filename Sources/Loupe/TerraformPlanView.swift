import AppKit
import LoupeCore
import LoupeInbox
import LoupeModel
import SwiftUI

/// A planned run's changes: a row for each resource, collapsed until expanded, then the "Plan:"
/// line and the outputs. Read-only text, so it can be selected and copied, and ⌘F searches every
/// resource's changes, expanding the one a match is in.
struct PlanOutlineView: NSViewRepresentable {
    let plans: TerraformPlans
    let check: TerraformPlanCheck
    let outline: TerraformPlanOutline
    let expanded: Set<String>
    let current: String?

    func makeNSView(context: Context) -> NSScrollView {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        // Lines aren't wrapped, so a value's structure keeps its indentation.
        container.widthTracksTextView = false
        layoutManager.addTextContainer(container)
        let textView = PlanTextView(frame: .zero, textContainer: container)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = .textBackgroundColor
        textView.textContainerInset = NSSize(width: PlanTextView.gutter, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setAccessibilityLabel("Terraform plan")

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        textView.finder.findBarContainer = scrollView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlanTextView else { return }
        let plans = plans
        let check = check
        textView.onExpand = { ids, isExpanded in plans.setExpanded(ids, isExpanded, in: check) }
        textView.onCurrent = { plans.setCurrent($0, in: check) }
        textView.show(outline, identity: check.runId, expanded: expanded, current: current)
    }
}

/// The plan's text, with each resource's row drawn as a band with a disclosure chevron in the
/// gutter. A click on a row (but not a drag across it) expands or collapses it, ⌥ doing every
/// row. ↑ and ↓ move between rows, → and ← expand and collapse, space and return toggle.
final class PlanTextView: NSTextView {
    static let gutter: CGFloat = 22

    let finder = NSTextFinder()
    private lazy var finderClient = PlanFinderClient(textView: self)
    var onExpand: (Set<String>, Bool) -> Void = { _, _ in }
    var onCurrent: (String?) -> Void = { _ in }

    private(set) var outline: TerraformPlanOutline?
    private(set) var shown: TerraformPlanOutline.Shown?
    private(set) var fullText = ""
    private(set) var expanded: Set<String> = []
    private(set) var current: String?
    private var identity: String?
    private var disclosures: [String: RowDisclosure] = [:]

    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        finder.client = finderClient
        finder.isIncrementalSearchingEnabled = true
        // Not in a snapshot run, whose off-screen window draws the dimmed plan blank, as it does
        // CircleCI's output, hiding what a snap is meant to show.
        finder.incrementalSearchingShouldDimContentView = SnapshotRun.directory == nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// Shows `outline` with `expanded`'s resources expanded, starting at the top for a new plan
    /// and staying where it was for the same one.
    func show(_ outline: TerraformPlanOutline, identity: String, expanded: Set<String>, current: String?) {
        let isNew = self.identity != identity
        self.current = current
        guard isNew || expanded != self.expanded else {
            needsDisplay = true
            return
        }
        if isNew {
            self.identity = identity
            self.outline = outline
            fullText = outline.fullText
            finder.noteClientStringWillChange()
        }
        apply(expanded, keepsPlace: !isNew)
        if isNew { scroll(.zero) }
    }

    /// Expands or collapses `ids`, telling the plans.
    func setExpanded(_ ids: Set<String>, _ isExpanded: Bool) {
        let next = isExpanded ? expanded.union(ids) : expanded.subtracting(ids)
        guard next != expanded else { return }
        apply(next, keepsPlace: true)
        finder.noteClientStringWillChange()
        onExpand(ids, isExpanded)
    }

    func toggle(_ id: String, all: Bool) {
        let ids = all ? Set(outline?.resources.map(\.id) ?? []) : [id]
        setExpanded(ids, !expanded.contains(id))
        setCurrent(id)
    }

    /// Lays the text out again with `expanded`'s resources expanded, keeping the selection and,
    /// when `keepsPlace`, the scroll position.
    private func apply(_ expanded: Set<String>, keepsPlace: Bool) {
        guard let outline, let textStorage else { return }
        let selection = shown.map { $0.fullRange(forShown: selectedRange()) }
        let origin = enclosingScrollView?.contentView.bounds.origin
        self.expanded = expanded
        let shown = outline.shown(expanded: expanded)
        self.shown = shown
        textStorage.setAttributedString(shown.text)
        setAccessibilityValue(string)
        let selected = selection.flatMap { shown.shownRange(forFull: $0) } ?? NSRange(location: 0, length: 0)
        setSelectedRange(selected)
        if keepsPlace, let origin, let clipView = enclosingScrollView?.contentView {
            layoutManager?.ensureLayout(for: textContainer!)
            sizeToFit()
            clipView.scroll(to: clipView.constrainBoundsRect(NSRect(origin: origin, size: clipView.bounds.size)).origin)
            enclosingScrollView?.reflectScrolledClipView(clipView)
        }
        disclosures = Dictionary(uniqueKeysWithValues: shown.rows.map { row in
            (row.id, disclosures[row.id] ?? RowDisclosure(textView: self, id: row.id))
        })
        NSAccessibility.post(element: self, notification: .layoutChanged)
        needsDisplay = true
    }

    private func setCurrent(_ id: String?) {
        current = id
        onCurrent(id)
        needsDisplay = true
    }

    // MARK: Rows

    /// A row's band, across the whole width, in this view's coordinates.
    func rowRect(_ range: NSRange) -> NSRect {
        guard let layoutManager, range.length > 0 else { return .zero }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let first = layoutManager.lineFragmentRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let last = layoutManager.lineFragmentRect(forGlyphAt: max(glyphs.location, NSMaxRange(glyphs) - 1), effectiveRange: nil)
        let origin = textContainerOrigin
        return NSRect(x: 0, y: first.minY + origin.y, width: max(bounds.width, visibleRect.maxX), height: last.maxY - first.minY)
    }

    /// Where a row's chevron is drawn and clicked.
    func chevronRect(_ range: NSRange) -> NSRect {
        guard let layoutManager, range.length > 0 else { return .zero }
        let glyph = layoutManager.glyphIndexForCharacter(at: range.location)
        let line = layoutManager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let midY = line.midY + textContainerOrigin.y
        return NSRect(x: 4, y: midY - 8, width: 16, height: 16)
    }

    private func row(at point: NSPoint) -> (id: String, range: NSRange)? {
        shown?.rows.first { rowRect($0.range).minY <= point.y && point.y < rowRect($0.range).maxY }
    }

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let shown, let outline else { return }
        let actions = Dictionary(uniqueKeysWithValues: outline.resources.map { ($0.id, $0.action) })
        let isFocused = window?.firstResponder === self
        for row in shown.rows {
            let band = rowRect(row.range)
            guard band.intersects(rect) else { continue }
            bandColor(actions[row.id] ?? .none).setFill()
            band.fill()
            NSColor.separatorColor.setFill()
            NSRect(x: band.minX, y: band.minY, width: band.width, height: 1).fill()
            if row.id == current {
                (isFocused ? NSColor.controlAccentColor : NSColor.secondaryLabelColor).setFill()
                NSRect(x: band.minX, y: band.minY, width: 3, height: band.height).fill()
            }
            drawChevron(expanded.contains(row.id), in: chevronRect(row.range))
        }
    }

    private func drawChevron(_ isExpanded: Bool, in rect: NSRect) {
        let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(hierarchicalColor: .secondaryLabelColor))
        guard let image = NSImage(systemSymbolName: isExpanded ? "chevron.down" : "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
    }

    // MARK: Input

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let row = row(at: point) else { return super.mouseDown(with: event) }
        let all = event.modifierFlags.contains(.option)
        if point.x < textContainerOrigin.x {
            window?.makeFirstResponder(self)
            toggle(row.id, all: all)
            return
        }
        super.mouseDown(with: event)
        // A click toggles; a drag selects, and a double-click selects a word.
        if event.clickCount == 1, selectedRange().length == 0 {
            toggle(row.id, all: all)
        } else {
            setCurrent(row.id)
        }
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty || modifiers == .option, let shown, !shown.rows.isEmpty else { return super.keyDown(with: event) }
        let all = modifiers == .option
        let ids = shown.rows.map(\.id)
        switch event.specialKey {
        case .downArrow?, .upArrow?:
            let step = event.specialKey == .downArrow ? 1 : -1
            let index = current.flatMap(ids.firstIndex(of:)).map { min(max($0 + step, 0), ids.count - 1) } ?? (step > 0 ? 0 : ids.count - 1)
            setCurrent(ids[index])
            scrollRowToVisible(ids[index])
        case .rightArrow?, .leftArrow?:
            let isExpanding = event.specialKey == .rightArrow
            if all {
                setExpanded(Set(ids), isExpanding)
            } else if let current {
                setExpanded([current], isExpanding)
            }
        default:
            guard modifiers.isEmpty, event.characters == " " || event.characters == "\r", let current else { return super.keyDown(with: event) }
            toggle(current, all: false)
        }
    }

    private func scrollRowToVisible(_ id: String) {
        guard let range = shown?.rows.first(where: { $0.id == id })?.range else { return }
        let band = rowRect(range)
        scrollToVisible(NSRect(x: visibleRect.minX, y: band.minY - 8, width: 1, height: band.height + 16))
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    // MARK: Find

    /// ⌘F, ⌘G and the rest go to the plan's own finder, which searches collapsed resources too.
    override func performTextFinderAction(_ sender: Any?) {
        guard let tag = (sender as? NSValidatedUserInterfaceItem)?.tag, let action = NSTextFinder.Action(rawValue: tag) else { return }
        finder.performAction(action)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(performTextFinderAction(_:)), let action = NSTextFinder.Action(rawValue: item.tag) {
            return finder.validateAction(action)
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Expands whatever collapsed resources hold `range` of the full text, and says where it's
    /// shown.
    func reveal(_ range: NSRange) -> NSRange? {
        guard let shown else { return nil }
        let hidden = shown.collapsedResources(holding: range)
        if !hidden.isEmpty {
            let next = expanded.union(hidden)
            apply(next, keepsPlace: true)
            onExpand(hidden, true)
            if let id = hidden.first { setCurrent(id) }
        }
        return self.shown?.shownRange(forFull: range)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        let rows = shown?.rows.compactMap { disclosures[$0.id] } ?? []
        return (super.accessibilityChildren() ?? []) + rows
    }

    func isExpanded(_ id: String) -> Bool { expanded.contains(id) }

    func title(of id: String) -> String {
        outline?.resources.first { $0.id == id }?.title ?? id
    }

    /// Where a range of the shown text is drawn, a rect for each line it's on.
    func rects(forShown range: NSRange) -> [NSRect] {
        guard let layoutManager, let textContainer else { return [] }
        let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        var rects: [NSRect] = []
        let origin = textContainerOrigin
        layoutManager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: textContainer) { rect, _ in
            rects.append(rect.offsetBy(dx: origin.x, dy: origin.y))
        }
        return rects
    }

    func chevronRect(of id: String) -> NSRect? {
        shown?.rows.first { $0.id == id }.map { chevronRect($0.range) }
    }
}

/// A row's disclosure, as VoiceOver and a UI script find it: labelled with the row's text,
/// saying whether it's expanded, and pressed to toggle it.
private final class RowDisclosure: NSAccessibilityElement {
    private weak var textView: PlanTextView?
    private let id: String

    init(textView: PlanTextView, id: String) {
        self.textView = textView
        self.id = id
        super.init()
        setAccessibilityRole(.disclosureTriangle)
        setAccessibilityParent(textView)
    }

    override func accessibilityLabel() -> String? {
        onMain { $0.title(of: $1) }
    }

    override func accessibilityValue() -> Any? {
        isAccessibilityExpanded() ? 1 : 0
    }

    override func isAccessibilityExpanded() -> Bool {
        onMain { $0.isExpanded($1) } ?? false
    }

    override func accessibilityFrame() -> NSRect {
        onMain { textView, id in
            guard let rect = textView.chevronRect(of: id), let window = textView.window else { return .zero }
            return window.convertToScreen(textView.convert(rect, to: nil))
        } ?? .zero
    }

    override func isAccessibilityEnabled() -> Bool { true }

    override func accessibilityPerformPress() -> Bool {
        onMain { textView, id in
            textView.toggle(id, all: false)
            return true
        } ?? false
    }

    /// Accessibility asks on the main thread, where the text view lives.
    private func onMain<T: Sendable>(_ body: @MainActor (PlanTextView, String) -> T) -> T? {
        let textView = textView
        let id = id
        return MainActor.assumeIsolated {
            guard let textView else { return nil }
            return body(textView, id)
        }
    }
}

/// The finder's view of the plan: the full text, every resource expanded, so a match in a
/// collapsed one is found, and that resource expanded to show it.
@MainActor
private final class PlanFinderClient: NSObject, @preconcurrency NSTextFinderClient {
    private weak var textView: PlanTextView?

    init(textView: PlanTextView) {
        self.textView = textView
    }

    var string: String { textView?.fullText ?? "" }
    var isSelectable: Bool { true }
    var allowsMultipleSelection: Bool { false }
    var isEditable: Bool { false }

    var firstSelectedRange: NSRange {
        guard let textView, let shown = textView.shown else { return NSRange(location: 0, length: 0) }
        return shown.fullRange(forShown: textView.selectedRange())
    }

    var selectedRanges: [NSValue] {
        get { [NSValue(range: firstSelectedRange)] }
        set {
            guard let textView, let range = newValue.first?.rangeValue, let shownRange = textView.reveal(range) else { return }
            textView.setSelectedRange(shownRange)
        }
    }

    func scrollRangeToVisible(_ range: NSRange) {
        guard let textView, let shownRange = textView.reveal(range) else { return }
        textView.scrollRangeToVisible(shownRange)
    }

    var visibleCharacterRanges: [NSValue] {
        guard let textView, let shown = textView.shown, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return [] }
        var visible = textView.visibleRect
        visible.origin.x -= textView.textContainerOrigin.x
        visible.origin.y -= textView.textContainerOrigin.y
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        return [NSValue(range: shown.fullRange(forShown: characters))]
    }

    func contentView(at index: Int, effectiveCharacterRange outRange: NSRangePointer) -> NSView {
        outRange.pointee = NSRange(location: 0, length: (string as NSString).length)
        return textView ?? NSView()
    }

    func rects(forCharacterRange range: NSRange) -> [NSValue]? {
        guard let textView, let shownRange = textView.shown?.shownRange(forFull: range) else { return nil }
        return textView.rects(forShown: shownRange).map { NSValue(rect: $0) }
    }

    /// The match in the find indicator, as a text view draws one: dark text on the find
    /// highlight.
    func drawCharacters(in range: NSRange, forContentView view: NSView) {
        guard let textView, let shownRange = textView.shown?.shownRange(forFull: range) else { return }
        let rects = textView.rects(forShown: shownRange)
        NSColor.findHighlightColor.setFill()
        rects.forEach { $0.fill() }
        let match = NSMutableAttributedString(attributedString: textView.attributedSubstring(forProposedRange: shownRange, actualRange: nil) ?? NSAttributedString())
        let whole = NSRange(location: 0, length: match.length)
        match.addAttribute(.foregroundColor, value: NSColor.black, range: whole)
        match.removeAttribute(.paragraphStyle, range: whole)
        if let first = rects.first { match.draw(at: first.origin) }
    }
}

/// The row band's tint: Terraform's add and destroy colours, faint, and grey for the rest.
private func bandColor(_ action: TerraformPlanOutline.Action) -> NSColor {
    switch action {
    case .create: DiffColors.additionBackground
    case .delete, .replace: DiffColors.deletionBackground
    case .update, .read, .none: .quaternarySystemFill
    }
}
