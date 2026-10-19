import AppKit
import LoupeModel
import SwiftUI

/// What resting the pointer on the checks glyph shows, as github.com's checks popover does: how
/// the checks went, then each check, failing first, opening its page when clicked.
struct ChecksPopoverContent: View {
    let state: CheckState
    /// Empty until looked up, when only the overall state is named.
    let contexts: [CheckContext]
    /// Told when the pointer enters or leaves the popover, so it stays while being read.
    var onPointerOver: (Bool) -> Void = { _ in }
    /// Told when a check's page has been opened, so the popover can go.
    var onOpen: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: contexts.summary ?? overallState)
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            if !contexts.isEmpty {
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(contexts.failingFirst.enumerated()), id: \.offset) { _, check in
                            CheckRow(check: check, onOpen: onOpen)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 380, alignment: .leading)
        .onHover(perform: onPointerOver)
    }

    private var overallState: String {
        switch state {
        case .success: "Checks passed"
        case .failure, .error: "Checks failed"
        case .pending, .expected: "Checks running"
        case .unknown: "Unknown check state"
        }
    }
}

/// Opens an `NSPopover` of `content` once the pointer has rested on the view it's behind, and
/// closes it once the pointer has left both for a moment, fading quickly either way. An
/// `NSPopover` rather than SwiftUI's `.popover`, as it's shown on hover and must leave the
/// keyboard where it was.
struct ChecksPopoverAnchor: NSViewRepresentable {
    let content: ChecksPopoverContent

    func makeNSView(context: Context) -> AnchorView { AnchorView(content: content) }
    func updateNSView(_ view: AnchorView, context: Context) { view.content = content }
    static func dismantleNSView(_ view: AnchorView, coordinator: ()) { view.closePopover() }

    final class AnchorView: NSView, NSPopoverDelegate {
        /// How long the pointer rests on the glyph before the popover opens: well under a
        /// tooltip's delay, but long enough that sweeping or scrolling past doesn't open it.
        static let dwell = Duration.milliseconds(120)
        /// How long the pointer may be off both glyph and popover, to cross the gap between them.
        static let grace = Duration.milliseconds(150)
        /// How long the popover fades in or out, in place of `NSPopover`'s much slower animation.
        static let fade: TimeInterval = 0.08

        var content: ChecksPopoverContent {
            didSet { hosting?.rootView = reporting(content) }
        }
        private var popover: NSPopover?
        private var hosting: NSHostingController<ChecksPopoverContent>?
        private var isPointerOverPopover = false
        /// Waiting out the dwell before opening, or the grace before closing.
        private var waiting: Task<Void, Never>?

        init(content: ChecksPopoverContent) {
            self.content = content
            super.init(frame: .zero)
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used from a nib") }

        override func mouseEntered(with event: NSEvent) {
            if popover == nil { awaitDwell() } else { waiting?.cancel() }
        }

        override func mouseExited(with event: NSEvent) {
            pointerLeft()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { closePopover() }
        }

        func showPopover() {
            guard popover == nil, let window else { return }
            let hosting = NSHostingController(rootView: reporting(content))
            hosting.sizingOptions = .preferredContentSize
            let popover = NSPopover()
            popover.behavior = .transient
            popover.contentViewController = hosting
            popover.delegate = self
            popover.animates = false
            let wasKey = window.isKeyWindow
            popover.show(relativeTo: bounds, of: self, preferredEdge: .minY)
            // Made clear before it's first drawn, then faded in.
            if let shown = hosting.view.window {
                shown.alphaValue = 0
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Self.fade
                    shown.animator().alphaValue = 1
                }
            }
            // The list or diff keeps the keyboard; the popover is only to read and click.
            if wasKey, !window.isKeyWindow { window.makeKey() }
            self.popover = popover
            self.hosting = hosting
        }

        func closePopover() {
            waiting?.cancel()
            guard let popover else { return }
            guard let shown = popover.contentViewController?.view.window else { return popover.close() }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.fade
                shown.animator().alphaValue = 0
            } completionHandler: {
                MainActor.assumeIsolated { popover.close() }
            }
        }

        func popoverDidClose(_ notification: Notification) {
            popover = nil
            hosting = nil
            isPointerOverPopover = false
        }

        /// Opens the popover once the pointer has rested on the glyph for the dwell. If the glyph
        /// moved meanwhile, it was scrolled under the pointer, so the wait starts again.
        private func awaitDwell() {
            waiting?.cancel()
            let place = placeInWindow
            waiting = Task { [weak self] in
                try? await Task.sleep(for: Self.dwell)
                guard let self, !Task.isCancelled, isPointerInside else { return }
                if placeInWindow == place { showPopover() } else { awaitDwell() }
            }
        }

        private func pointerLeft() {
            waiting?.cancel()
            guard popover != nil else { return }
            waiting = Task { [weak self] in
                try? await Task.sleep(for: Self.grace)
                guard let self, !Task.isCancelled, !isPointerInside, !isPointerOverPopover else { return }
                closePopover()
            }
        }

        private func reporting(_ content: ChecksPopoverContent) -> ChecksPopoverContent {
            var content = content
            content.onPointerOver = { [weak self] isOver in
                guard let self else { return }
                isPointerOverPopover = isOver
                if isOver { waiting?.cancel() } else { pointerLeft() }
            }
            content.onOpen = { [weak self] in self?.closePopover() }
            return content
        }

        private var placeInWindow: NSRect { convert(bounds, to: nil) }

        /// Asked of the window rather than kept from entered and exited events, which scrolling
        /// doesn't always send.
        private var isPointerInside: Bool {
            guard let window else { return false }
            return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        }
    }
}

/// One check: its status, name and description, opening its page when it has one.
private struct CheckRow: View {
    let check: CheckContext
    let onOpen: () -> Void
    @State private var isHovered = false

    var body: some View {
        if let url = check.url.flatMap(URL.init(string:)) {
            Button {
                openInBrowser(url)
                onOpen()
            } label: {
                label.background(isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            // Pointed at and clicked, never tabbed to, so no row shows a focus ring.
            .focusable(false)
            .onHover { isOver in
                guard isOver != isHovered else { return }
                isHovered = isOver
                if isOver { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .onDisappear {
                if isHovered { NSCursor.pop() }
                isHovered = false
            }
        } else {
            label
        }
    }

    private var label: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            CheckStatusGlyph(check: check)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: check.name)
                if let description = check.description, !description.isEmpty {
                    Text(verbatim: description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .lineLimit(1)
            .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
    }
}

/// One check's outcome as a coloured glyph, matching the overall one. A tolerated failure's
/// cross is in the secondary colour, as it doesn't make the checks fail.
private struct CheckStatusGlyph: View {
    let check: CheckContext

    var body: some View {
        Group {
            switch check.status {
            case .success: Image(systemName: "checkmark").foregroundStyle(.diffSuccess)
            case .failure where check.isToleratedFailure: Image(systemName: "xmark").foregroundStyle(.secondary)
            case .failure: Image(systemName: "xmark").foregroundStyle(.diffDanger)
            case .pending: Image(systemName: "clock").foregroundStyle(.orange)
            case .neutral: Image(systemName: "minus").foregroundStyle(.secondary)
            }
        }
        .fontWeight(.semibold)
    }
}
