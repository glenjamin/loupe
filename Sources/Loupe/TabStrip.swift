import AppKit

/// The window's content: the tab strip across the top and, below it, the lists or one PR. Each
/// content stays made once shown and is only hidden when another is selected, so a PR keeps its
/// diff, scroll positions and conversation as a window of its own would.
@MainActor
final class TabbedContentController: NSViewController {
    let strip = TabStripView()
    private let contentArea = NSView()
    /// Keyed by PR id, nil for the lists.
    private var contents: [String?: NSViewController] = [:]
    /// What had the focus in each content when it was last hidden, to give it back on return.
    private var responders: [String?: WeakResponder] = [:]
    private var shown: String??

    override func loadView() {
        let view = NSView()
        for subview in [strip, contentArea] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(subview)
        }
        NSLayoutConstraint.activate([
            strip.topAnchor.constraint(equalTo: view.topAnchor),
            strip.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: TabStripView.height),
            contentArea.topAnchor.constraint(equalTo: strip.bottomAnchor),
            contentArea.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentArea.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentArea.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.view = view
    }

    /// Shows the content for `id`, making it with `make` the first time.
    func show(_ id: String?, make: () -> NSViewController) {
        guard shown != .some(id) else { return }
        if let shown, let previous = contents[shown], let responder = view.window?.firstResponder as? NSView,
           responder.isDescendant(of: previous.view) {
            responders[shown] = WeakResponder(responder)
        }
        let controller = contents[id] ?? add(make(), for: id)
        for (key, content) in contents { content.view.isHidden = key != id }
        shown = id
        if let window = view.window {
            let responder = responders[id]?.view.flatMap { $0.isDescendant(of: controller.view) ? $0 : nil }
            window.makeFirstResponder(responder ?? controller.view)
        }
    }

    /// Drops the content of every PR not in `ids`, as their tabs have closed.
    func discard(keeping ids: Set<String>) {
        for case let key? in contents.keys where !ids.contains(key) {
            contents[key]?.view.removeFromSuperview()
            contents[key]?.removeFromParent()
            contents[key] = nil
            responders[key] = nil
        }
    }

    private func add(_ controller: NSViewController, for id: String?) -> NSViewController {
        addChild(controller)
        let content = controller.view
        content.frame = contentArea.bounds
        content.autoresizingMask = [.width, .height]
        contentArea.addSubview(content)
        contents[id] = controller
        return controller
    }
}

/// One item of the strip: the lists, or an open PR.
struct TabStripItem: Equatable {
    /// Nil for the lists.
    let id: String?
    let title: String
    let subtitle: String
}

/// The strip under the title bar: a "Pull Requests" button that is always first and shows the
/// lists, then a two-row tab per open PR. It's AppKit rather than SwiftUI so clicks land
/// reliably, and nothing in it drags the window.
@MainActor
final class TabStripView: NSView {
    static let height: CGFloat = 46
    var onSelect: @MainActor (String?) -> Void = { _ in }
    var onClose: @MainActor (String) -> Void = { _ in }

    private let listsButton = TabStripItemView(isLists: true)
    private var tabViews: [TabStripItemView] = []
    private static let listsWidth: CGFloat = 150
    private static let tabWidths: ClosedRange<CGFloat> = 120...260

    override init(frame: NSRect) {
        super.init(frame: frame)
        listsButton.item = TabStripItem(id: nil, title: "Pull Requests", subtitle: "")
        listsButton.onSelect = { [weak self] in self?.onSelect(nil) }
        addSubview(listsButton)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Shows `tabs` after the lists button, marking `selected` (nil for the lists).
    func update(tabs: [TabStripItem], selected: String?) {
        while tabViews.count > tabs.count { tabViews.removeLast().removeFromSuperview() }
        while tabViews.count < tabs.count {
            let view = TabStripItemView(isLists: false)
            tabViews.append(view)
            addSubview(view)
        }
        for (view, item) in zip(tabViews, tabs) {
            view.item = item
            view.isSelected = item.id == selected
            view.onSelect = { [weak self] in self?.onSelect(item.id) }
            view.onClose = { [weak self] in if let id = item.id { self?.onClose(id) } }
        }
        listsButton.isSelected = selected == nil
        needsLayout = true
    }

    /// The centre of the item at `position` (0 for the lists, then each tab) in window
    /// coordinates, for a snapshot run to click.
    func centreInWindow(ofItemAt position: Int) -> NSPoint? {
        let items = [listsButton] + tabViews
        guard items.indices.contains(position) else { return nil }
        layoutSubtreeIfNeeded()
        let view = items[position]
        return view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
    }

    override func layout() {
        super.layout()
        listsButton.frame = NSRect(x: 0, y: 0, width: Self.listsWidth, height: bounds.height)
        guard !tabViews.isEmpty else { return }
        let share = (bounds.width - Self.listsWidth) / CGFloat(tabViews.count)
        let width = min(max(share, Self.tabWidths.lowerBound), Self.tabWidths.upperBound).rounded(.down)
        for (index, view) in tabViews.enumerated() {
            view.frame = NSRect(x: Self.listsWidth + CGFloat(index) * width, y: 0, width: width, height: bounds.height)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        StripColors.background(for: effectiveAppearance).setFill()
        bounds.fill()
        drawBottomEdge(of: bounds)
    }
}

/// The lists button or one PR's tab, drawing its own background so the selected one stands out.
@MainActor
private final class TabStripItemView: NSView {
    var item = TabStripItem(id: nil, title: "", subtitle: "") {
        didSet {
            guard item != oldValue else { return }
            titleLabel.stringValue = item.title
            subtitleLabel.stringValue = item.subtitle
            toolTip = item.subtitle.isEmpty ? item.title : "\(item.title)\n\(item.subtitle)"
            needsLayout = true
        }
    }
    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateCloseButton()
            needsDisplay = true
        }
    }
    var onSelect: @MainActor () -> Void = {}
    var onClose: @MainActor () -> Void = {}

    private let isLists: Bool
    private let titleLabel = label(font: .boldSystemFont(ofSize: 12), colour: .labelColor)
    private let subtitleLabel = label(font: .systemFont(ofSize: 11), colour: .secondaryLabelColor)
    private let icon = NSImageView()
    private let closeButton = NSButton()
    private var isHovered = false {
        didSet {
            updateCloseButton()
            needsDisplay = true
        }
    }
    private static let padding: CGFloat = 10
    private static let closeSize: CGFloat = 16

    init(isLists: Bool) {
        self.isLists = isLists
        super.init(frame: .zero)
        addSubview(titleLabel)
        if isLists {
            icon.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: nil)
            icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
            icon.contentTintColor = .secondaryLabelColor
            addSubview(icon)
        } else {
            addSubview(subtitleLabel)
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Tab")
            closeButton.symbolConfiguration = .init(pointSize: 9, weight: .semibold)
            closeButton.isBordered = false
            closeButton.imagePosition = .imageOnly
            closeButton.contentTintColor = .secondaryLabelColor
            closeButton.toolTip = "Close Tab"
            closeButton.target = self
            closeButton.action = #selector(close)
            addSubview(closeButton)
            updateCloseButton()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The labels and icon take no clicks of their own; the whole item does, bar the close button.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview, frame.contains(point) else { return nil }
        let local = convert(point, from: superview)
        if !closeButton.isHidden, closeButton.frame.insetBy(dx: -3, dy: -3).contains(local) { return closeButton }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        onSelect()
    }

    /// A middle click closes a tab, as browsers do; the lists have nothing to close.
    override func otherMouseUp(with event: NSEvent) {
        guard event.buttonNumber == 2, !isLists, bounds.contains(convert(event.locationInWindow, from: nil)) else {
            return super.otherMouseUp(with: event)
        }
        onClose()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func layout() {
        super.layout()
        let padding = Self.padding
        if isLists {
            let iconSize: CGFloat = 18
            icon.frame = NSRect(x: padding, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize)
            let height = titleLabel.intrinsicContentSize.height
            let x = icon.frame.maxX + 6
            titleLabel.frame = NSRect(x: x, y: (bounds.height - height) / 2, width: bounds.width - x - padding, height: height)
            return
        }
        // Space for the close button is kept even while it's hidden, so text never shifts.
        let textWidth = bounds.width - padding * 2 - Self.closeSize - 4
        let titleHeight = titleLabel.intrinsicContentSize.height
        let subtitleHeight = subtitleLabel.intrinsicContentSize.height
        let top = (bounds.height - titleHeight - subtitleHeight - 1) / 2
        titleLabel.frame = NSRect(x: padding, y: top, width: textWidth, height: titleHeight)
        subtitleLabel.frame = NSRect(x: padding, y: top + titleHeight + 1, width: textWidth, height: subtitleHeight)
        closeButton.frame = NSRect(x: bounds.width - padding - Self.closeSize, y: (bounds.height - Self.closeSize) / 2, width: Self.closeSize, height: Self.closeSize)
    }

    override func draw(_ dirtyRect: NSRect) {
        let appearance = effectiveAppearance
        (isSelected ? StripColors.selected(for: appearance) : isHovered ? StripColors.hovered(for: appearance) : StripColors.background(for: appearance)).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        drawBottomEdge(of: bounds)
    }

    @objc private func close() {
        onClose()
    }

    private func updateCloseButton() {
        closeButton.isHidden = isLists || !(isSelected || isHovered)
    }
}

/// The selected item is the title bar's own colour, so it reads as part of the chrome above; the
/// rest of the strip is a shade darker.
@MainActor
private enum StripColors {
    static func selected(for appearance: NSAppearance) -> NSColor {
        resolved(.windowBackgroundColor, in: appearance)
    }

    static func background(for appearance: NSAppearance) -> NSColor {
        shaded(by: isDark(appearance) ? 0.42 : 0.08, in: appearance)
    }

    static func hovered(for appearance: NSAppearance) -> NSColor {
        shaded(by: isDark(appearance) ? 0.21 : 0.04, in: appearance)
    }

    private static func shaded(by fraction: CGFloat, in appearance: NSAppearance) -> NSColor {
        let base = resolved(.windowBackgroundColor, in: appearance)
        return base.blended(withFraction: fraction, of: .black) ?? base
    }

    private static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private static func resolved(_ colour: NSColor, in appearance: NSAppearance) -> NSColor {
        var result = colour
        appearance.performAsCurrentDrawingAppearance { result = colour.usingColorSpace(.sRGB) ?? colour }
        return result
    }
}

/// A hairline along the bottom, between the strip and the content.
@MainActor
private func drawBottomEdge(of bounds: NSRect) {
    NSColor.separatorColor.setFill()
    NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
}

@MainActor
private func label(font: NSFont, colour: NSColor) -> NSTextField {
    let label = NSTextField(labelWithString: "")
    label.font = font
    label.textColor = colour
    label.lineBreakMode = .byTruncatingTail
    label.maximumNumberOfLines = 1
    label.cell?.truncatesLastVisibleLine = true
    return label
}

private struct WeakResponder {
    weak var view: NSView?

    init(_ view: NSView) {
        self.view = view
    }
}
