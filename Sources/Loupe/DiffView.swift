import AppKit
import LoupeCore
import SwiftUI

/// One file's diff under a header naming it, in a bordered box as on GitHub. Clicking a row
/// reports its comment anchor. A PR's file also has a "Reviewed" checkbox, and ends in a footer
/// that marks it reviewed and moves on.
struct DiffView: View {
    let file: FileDiff
    let onAnchorClick: (DiffAnchor) -> Void
    var review: FileReview?

    var body: some View {
        VStack(spacing: 0) {
            FileHeader(file: file, review: review)
            Divider()
            DiffTextScrollView(file: file, onAnchorClick: onAnchorClick, review: review)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        .padding(10)
    }
}

/// The file's path, with its directory dimmed, what happened to it, and its line counts.
private struct FileHeader: View {
    let file: FileDiff
    let review: FileReview?

    var body: some View {
        HStack(spacing: 10) {
            path
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            if let change {
                Text(change)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                Text(verbatim: "+\(file.additions)").foregroundStyle(.diffSuccess)
                Text(verbatim: "\u{2212}\(file.deletions)").foregroundStyle(.diffDanger)
            }
            .monospacedDigit()
            if let review {
                Toggle("Reviewed", isOn: Binding(get: { review.isViewed }, set: { _ in review.toggleViewed() }))
                    .toggleStyle(.checkbox)
                    .help("Mark this file reviewed on GitHub (⇧V)")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.bar)
    }

    private var path: Text {
        let directory = (file.path as NSString).deletingLastPathComponent
        let name = Text(verbatim: (file.path as NSString).lastPathComponent).font(.system(size: 12, weight: .semibold, design: .monospaced))
        guard !directory.isEmpty else { return name }
        return Text(verbatim: directory + "/").font(.system(size: 12, design: .monospaced)).foregroundColor(.secondary) + name
    }

    private var change: String? {
        switch file.change {
        case .modified: nil
        case .added: "New file"
        case .deleted: "Deleted"
        case .renamed(let from, _): "Renamed from \(from)"
        case .copied(let from, _): "Copied from \(from)"
        }
    }
}

/// A PR file's viewed state, and what the footer at the end of its diff does.
struct FileReview {
    let isViewed: Bool
    let toggleViewed: () -> Void
    /// Says what the footer's button, or pulling past the end, will do.
    let advanceLabel: String
    /// Revealed below the footer while pulling, saying what letting the pull fire will do.
    let pullHint: String
    let markViewedAndAdvance: () -> Void
}

/// The diff's text in a scroll view. A PR's file ends in a footer, inside the scrolled content,
/// whose button marks the file reviewed and moves on. Below the footer is some slack to scroll
/// into; pulling into it fills the button and does the same once far enough, as a shortcut for
/// a trackpad.
private struct DiffTextScrollView: NSViewRepresentable {
    let file: FileDiff
    let onAnchorClick: (DiffAnchor) -> Void
    let review: FileReview?
    @AppStorage(DiffSettings.wrapLinesKey) var wrapLines = DiffSettings.wrapLinesDefault

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let scroll = OverscrollScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView = FooterClipView()
        scroll.documentView = coordinator.textView
        // In the clip view, the footer is placed in the document's coordinates and so scrolls
        // with it, clipped like the text.
        scroll.contentView.addSubview(coordinator.footer)
        scroll.contentView.addSubview(coordinator.hint)
        scroll.onDrag = { [weak coordinator] began in coordinator?.drag(began: began) }
        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.textView.postsFrameChangedNotifications = true
        coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.review = review
        coordinator.footerState.label = review?.advanceLabel ?? ""
        coordinator.footerState.isViewed = review?.isViewed ?? false
        coordinator.footerState.pullHint = review?.pullHint ?? ""
        coordinator.textView.onAnchorClick = onAnchorClick
        scroll.hasHorizontalScroller = !wrapLines
        coordinator.textView.wrapsLines = wrapLines
        if coordinator.shownPath != file.path {
            coordinator.shownPath = file.path
            coordinator.stopSettling()
            coordinator.textView.show(RenderedDiff(file: file))
        }
        coordinator.footer.isHidden = review == nil
        coordinator.hint.isHidden = review == nil
        coordinator.layoutFooter()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        /// Room to scroll past the footer, comfortably more than the pull needs to fire.
        static let slack: CGFloat = 64

        let textView = DiffTextView.make()
        var shownPath: String?
        var review: FileReview?
        let footerState = ReviewFooterState()
        lazy var footer: NSHostingView<ReviewFooter> = {
            let view = NSHostingView(rootView: ReviewFooter(state: footerState) { [weak self] in
                self?.review?.markViewedAndAdvance()
            })
            view.sizingOptions = []
            return view
        }()
        /// Says what the pull will do, in the slack it's revealed by.
        lazy var hint: PullHintView = {
            let view = PullHintView(rootView: PullHint(state: footerState))
            view.sizingOptions = []
            return view
        }()
        private var trigger = OverscrollTrigger()
        private weak var scroll: OverscrollScrollView?
        private var fingersDown = false
        private var isSettling = false
        private var settleTask: Task<Void, Never>?
        private var observers: [any NSObjectProtocol] = []

        func observe(_ scroll: OverscrollScrollView) {
            self.scroll = scroll
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.scrolled() }
                },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutFooter() }
                },
            ]
        }

        /// Directly below the last row, across the visible width, so a short file has it
        /// straight after its content rather than at the bottom of the view. The content is
        /// inset at the bottom far enough to scroll the footer into view and then the slack.
        func layoutFooter() {
            guard let scroll else { return }
            let clip = scroll.contentView.bounds
            // At least the view's height, so the inset can't change how tall a short file's
            // text view stretches.
            if textView.minSize.height != clip.height {
                textView.minSize.height = clip.height
                if textView.frame.height < clip.height {
                    textView.setFrameSize(NSSize(width: textView.frame.width, height: clip.height))
                }
            }
            let top = contentBottom(clipHeight: clip.height)
            let frame = NSRect(x: clip.minX, y: top, width: clip.width, height: ReviewFooter.height)
            if footer.frame != frame { footer.frame = frame }
            let slack = NSRect(x: clip.minX, y: restingEnd(clipHeight: clip.height), width: clip.width, height: Self.slack)
            if hint.frame != slack { hint.frame = slack }
            let inset = review == nil ? 0 : max(0, restingEnd(clipHeight: clip.height) + Self.slack - textView.frame.maxY)
            if scroll.contentInsets.bottom != inset {
                scroll.contentInsets.bottom = inset
                // The scrollers keep to the whole height, over the footer too.
                scroll.scrollerInsets.bottom = -inset
            }
        }

        /// The fingers touching down to scroll, or lifting.
        func drag(began: Bool) {
            fingersDown = began
            guard review != nil else { return }
            if began {
                trigger.beginDrag()
            } else {
                trigger.endDrag()
            }
            show(trigger)
            settleSoon()
        }

        /// Stops any glide back from the slack, which would otherwise carry on into the next file.
        func stopSettling() {
            settleTask?.cancel()
            guard isSettling, let clip = scroll?.contentView else { return }
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                clip.animator().setBoundsOrigin(clip.bounds.origin)
            }
            isSettling = false
        }

        private func scrolled() {
            layoutFooter()
            guard let scroll, review != nil else { return }
            if trigger.scroll(overscroll: overscroll(in: scroll)) {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                // The fingers are likely still moving, and the next file shouldn't scroll with them.
                scroll.ignoresRestOfGesture = true
                review?.markViewedAndAdvance()
            }
            show(trigger)
            settleSoon()
        }

        /// Once scrolling stops with the view in the slack and the fingers lifted, glides it back
        /// so the footer ends the view again, as a rubber band springs back.
        private func settleSoon() {
            settleTask?.cancel()
            guard let scroll, !fingersDown, !isSettling, overscroll(in: scroll) > 0 else { return }
            settleTask = Task { [weak self] in
                guard (try? await Task.sleep(for: .milliseconds(150))) != nil else { return }
                self?.settle()
            }
        }

        private func settle() {
            guard let scroll, !fingersDown, overscroll(in: scroll) > 0 else { return }
            let clip = scroll.contentView
            let origin = NSPoint(x: clip.bounds.minX, y: restingEnd(clipHeight: clip.bounds.height) - clip.bounds.height)
            isSettling = true
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.25
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(origin)
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    self?.isSettling = false
                    self?.scroll?.reflectScrolledClipView(clip)
                }
            }
        }

        /// How far the view has scrolled into the slack below the footer, or negative if short
        /// of it.
        private func overscroll(in scroll: NSScrollView) -> CGFloat {
            let clip = scroll.contentView.bounds
            return clip.maxY - restingEnd(clipHeight: clip.height)
        }

        /// Where the bottom of the view rests when scrolled to the end, footer included.
        private func restingEnd(clipHeight: CGFloat) -> CGFloat {
            max(footer.frame.maxY, textView.frame.minY + clipHeight)
        }

        /// Where the last row ends. A text view stretches to fill the view, so a file shorter
        /// than the view ends above its frame; a longer one ends where its frame does.
        private func contentBottom(clipHeight: CGFloat) -> CGFloat {
            guard textView.frame.height <= clipHeight + 1, let layout = textView.layoutManager, let container = textView.textContainer else {
                return textView.frame.maxY
            }
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).maxY + textView.textContainerInset.height * 2
            return textView.frame.minY + min(textView.frame.height, used)
        }

        private func show(_ trigger: OverscrollTrigger) {
            footerState.progress = trigger.progress
            footerState.hasFired = trigger.hasFired
            footerState.isPulling = trigger.isDragging
        }
    }
}

/// Reports when the fingers touch down on the trackpad to scroll and when they lift, which
/// momentum scrolling afterwards doesn't count as.
private final class OverscrollScrollView: NSScrollView {
    var onDrag: (_ began: Bool) -> Void = { _ in }
    /// Drops the rest of the current trackpad gesture, momentum included, until the next begins.
    var ignoresRestOfGesture = false

    override func scrollWheel(with event: NSEvent) {
        let isGesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        if event.phase.contains(.began) || !isGesture { ignoresRestOfGesture = false }
        if event.phase.contains(.began) { onDrag(true) }
        if !ignoresRestOfGesture { super.scrollWheel(with: event) }
        if !event.phase.isDisjoint(with: [.ended, .cancelled]) { onDrag(false) }
    }
}

/// A clip view whose clicks also reach the views placed beside its document, such as the footer
/// below the last row. A plain clip view hit-tests only within its document view's frame.
private final class FooterClipView: NSClipView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for view in subviews.reversed() where view !== documentView && !view.isHidden {
            if let hit = view.hitTest(local) { return hit }
        }
        return super.hitTest(point)
    }
}

/// Holds the pull's hint, which is only a caption, so clicks pass through it.
final class PullHintView: NSHostingView<PullHint> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@Observable
@MainActor
final class ReviewFooterState {
    var progress: CGFloat = 0
    var hasFired = false
    /// A live drag is filling the button, as opposed to settling back after one.
    var isPulling = false
    var isViewed = false
    var label = ""
    var pullHint = ""
}

/// The end of a PR file's diff: a bar like the file's header, with a button that marks the file
/// reviewed and shows the next. Pulling past the end fills the button from the left, turning it
/// green as it fires.
struct ReviewFooter: View {
    static let height: CGFloat = 56

    let state: ReviewFooterState
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: action) {
                Label(state.label, systemImage: state.hasFired ? "checkmark.circle.fill" : state.isViewed ? "arrow.down.circle" : "checkmark.circle")
            }
            .buttonStyle(PullFillButtonStyle(progress: state.progress, hasFired: state.hasFired))
            .help("Or pull past the end of the diff (⌘↓)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.bar)
        .animation(.easeOut(duration: 0.12), value: state.hasFired)
    }
}

/// A caption in the slack below the footer, like pull-to-refresh's, fading in as a drag pulls
/// into the slack and saying what was done as it fires. Nothing shows at rest or while the view
/// settles back from a pull let go short.
struct PullHint: View {
    let state: ReviewFooterState

    var body: some View {
        Text(state.hasFired ? (state.isViewed ? state.label : "Marked reviewed") : state.pullHint)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(state.hasFired ? 1 : state.isPulling ? state.progress : 0)
            .animation(.easeOut(duration: 0.12), value: state.hasFired)
    }
}

/// A large push button, as AppKit draws one, whose bezel fills from the left with the pull's
/// progress: accent while filling, green once it fires.
private struct PullFillButtonStyle: ButtonStyle {
    let progress: CGFloat
    let hasFired: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label
            .padding(.horizontal, 14)
            .frame(height: 28)
            .background {
                shape
                    .fill(Color(nsColor: .controlColor))
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Rectangle()
                                .fill((hasFired ? Color.diffSuccess : Color.accentColor).opacity(hasFired ? 0.6 : 0.4))
                                .frame(width: geometry.size.width * progress)
                        }
                    }
                    .overlay {
                        if configuration.isPressed { Color.primary.opacity(0.12) }
                    }
                    .clipShape(shape)
                    .overlay(shape.strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.18), radius: 0.5, y: 0.5)
            }
            .contentShape(shape)
    }
}
