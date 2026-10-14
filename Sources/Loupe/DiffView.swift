import AppKit
import LoupeCore
import SwiftUI

/// One file's diff under a header naming it, in a bordered box as on GitHub. Clicking a row
/// reports its comment anchor. A PR's file also has a "Reviewed" checkbox, and ends in a footer
/// that marks it reviewed and moves on. A PR's markdown file can be shown rendered instead.
struct DiffView: View {
    let file: FileDiff
    let onAnchorClick: (DiffAnchor) -> Void
    var review: FileReview?
    var markdown: MarkdownPreview?

    var body: some View {
        VStack(spacing: 0) {
            FileHeader(file: file, review: review, markdown: markdown)
            Divider()
            // The rendering covers the diff rather than replacing it, so the diff keeps its place.
            ZStack {
                DiffTextScrollView(file: file, onAnchorClick: onAnchorClick, review: review)
                if let markdown, markdown.isRendered {
                    RenderedMarkdownView(preview: markdown)
                }
            }
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
    let markdown: MarkdownPreview?

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
            if let markdown {
                Picker("Show", selection: Binding(get: { markdown.isRendered }, set: markdown.setRendered)) {
                    Text("Source").tag(false)
                    Text("Rendered").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Show the diff, or the file as GitHub renders it")
            }
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
/// whose button marks the file reviewed and moves on. Pulling past the footer on a trackpad, like
/// pull-to-refresh, fills the button and does the same when let go far enough.
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
        // The rubber band is the stretch the user sees while pulling, even in a short file.
        scroll.verticalScrollElasticity = .allowed
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentView = FooterClipView()
        scroll.documentView = coordinator.textView
        // In the clip view, the footer is placed in the document's coordinates and so scrolls
        // with it, clipped like the text.
        scroll.contentView.addSubview(coordinator.footer)
        scroll.contentView.addSubview(coordinator.hint)
        scroll.isAtEnd = { [weak coordinator] in coordinator?.isAtEnd ?? false }
        scroll.onPull = { [weak coordinator] event in coordinator?.pull(event) }
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
            coordinator.pull(.cancelled)
            coordinator.textView.show(RenderedDiff(file: file))
        }
        coordinator.footer.isHidden = review == nil
        coordinator.hint.isHidden = review == nil
        coordinator.layoutFooter()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        /// Room for the hint in the gap the rubber band opens below the footer.
        static let hintHeight: CGFloat = 36

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
        /// Says what the pull will do, in the gap the rubber band opens below the footer.
        lazy var hint: PullHintView = {
            let view = PullHintView(rootView: PullHint(state: footerState))
            view.sizingOptions = []
            return view
        }()
        private var trigger = OverscrollTrigger()
        private weak var scroll: NSScrollView?
        private var observers: [any NSObjectProtocol] = []

        func observe(_ scroll: NSScrollView) {
            self.scroll = scroll
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutFooter() }
                },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.layoutFooter() }
                },
            ]
        }

        /// Directly below the last row, across the visible width, so a short file has it
        /// straight after its content rather than at the bottom of the view. The content is
        /// inset at the bottom only as far as the footer needs to be scrolled to.
        func layoutFooter() {
            guard let scroll else { return }
            let clip = scroll.contentView.bounds
            // At least the view's height, so a short file can still be pulled past its end and
            // the inset can't change how tall its text view stretches.
            if textView.minSize.height != clip.height {
                textView.minSize.height = clip.height
                if textView.frame.height < clip.height {
                    textView.setFrameSize(NSSize(width: textView.frame.width, height: clip.height))
                }
            }
            let top = contentBottom(clipHeight: clip.height)
            let frame = NSRect(x: clip.minX, y: top, width: clip.width, height: ReviewFooter.height)
            if footer.frame != frame { footer.frame = frame }
            let gap = NSRect(x: clip.minX, y: restingEnd(clipHeight: clip.height), width: clip.width, height: Self.hintHeight)
            if hint.frame != gap { hint.frame = gap }
            let inset = review == nil ? 0 : max(0, frame.maxY - textView.frame.maxY)
            if scroll.contentInsets.bottom != inset {
                scroll.contentInsets.bottom = inset
                // The scrollers keep to the whole height, over the footer too.
                scroll.scrollerInsets.bottom = -inset
            }
        }

        /// Whether the view is scrolled to its end, footer fully shown, or stretched past it.
        var isAtEnd: Bool {
            guard let clip = scroll?.contentView.bounds else { return false }
            return clip.maxY >= restingEnd(clipHeight: clip.height) - 1
        }

        func pull(_ event: PullEvent) {
            guard review != nil else { return }
            switch event {
            case .began:
                trigger.beginDrag()
            case .moved(let distance):
                if trigger.pull(by: distance) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
            case .ended:
                if trigger.endDrag() { review?.markViewedAndAdvance() }
            case .cancelled:
                trigger.cancelDrag()
            }
            footerState.progress = trigger.progress
            footerState.isArmed = trigger.isArmed
            footerState.isPulling = trigger.isDragging
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
    }
}

/// What a live trackpad drag does to the pull. Momentum and mouse wheels have no part in it.
enum PullEvent {
    case began
    /// The fingers moved this far with the view at its end: positive pulls the content further
    /// past it, negative back.
    case moved(CGFloat)
    case ended
    case cancelled
}

/// Reports a live trackpad drag's touch down, its travel while the view is at its end, and its
/// lift, leaving the scrolling and its rubber band to AppKit.
private final class OverscrollScrollView: NSScrollView {
    var isAtEnd: () -> Bool = { false }
    var onPull: (PullEvent) -> Void = { _ in }

    override func scrollWheel(with event: NSEvent) {
        let phase = event.phase
        if phase.contains(.began) { onPull(.began) }
        // Checked before the event scrolls, so travel spent reaching the end doesn't count. The
        // delta already follows the content, natural scrolling or not; negative moves it up.
        if !phase.isDisjoint(with: [.began, .changed]), event.hasPreciseScrollingDeltas, isAtEnd() {
            onPull(.moved(-event.scrollingDeltaY))
        }
        super.scrollWheel(with: event)
        if phase.contains(.ended) { onPull(.ended) }
        if phase.contains(.cancelled) { onPull(.cancelled) }
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
    /// Far enough that letting go now would mark the file reviewed and move on.
    var isArmed = false
    /// The fingers are down on the trackpad, so the fill follows them.
    var isPulling = false
    var isViewed = false
    var label = ""
    var pullHint = ""
}

/// The end of a PR file's diff: a bar like the file's header, with a button that marks the file
/// reviewed and shows the next. Pulling past the end fills the button from the left, turning it
/// green once letting go would do the same, and it empties as the pull is let go.
struct ReviewFooter: View {
    static let height: CGFloat = 56

    let state: ReviewFooterState
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button(action: action) {
                Label(state.label, systemImage: state.isArmed ? "checkmark.circle.fill" : state.isViewed ? "arrow.down.circle" : "checkmark.circle")
            }
            .buttonStyle(PullFillButtonStyle(progress: state.progress, isArmed: state.isArmed))
            .help("Or pull past the end of the diff (⌘↓)")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.bar)
        .animation(.easeOut(duration: 0.12), value: state.isArmed)
        // Follows the fingers exactly, and empties smoothly as the rubber band springs back.
        .animation(state.isPulling ? nil : .easeOut(duration: 0.25), value: state.progress)
    }
}

/// A caption in the rubber band's gap below the footer, like pull-to-refresh's, fading in with
/// a live drag's progress and saying what letting go will have done once armed. Nothing shows
/// at rest or once the fingers lift.
struct PullHint: View {
    let state: ReviewFooterState

    var body: some View {
        Text(state.isArmed ? (state.isViewed ? state.label : "Marked reviewed") : state.pullHint)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(state.isPulling ? state.progress : 0)
            .animation(.easeOut(duration: 0.12), value: state.isPulling)
    }
}

/// A large push button, as AppKit draws one, whose bezel fills from the left with the pull's
/// progress: accent while filling, green once letting go would fire it.
private struct PullFillButtonStyle: ButtonStyle {
    let progress: CGFloat
    let isArmed: Bool

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
                                .fill((isArmed ? Color.diffSuccess : Color.accentColor).opacity(isArmed ? 0.6 : 0.4))
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
