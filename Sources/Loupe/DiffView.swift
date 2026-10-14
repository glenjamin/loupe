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
    let markViewedAndAdvance: () -> Void
}

/// The diff's text in a scroll view. A PR's file ends in a footer, inside the scrolled content,
/// whose button marks the file reviewed and moves on. Pulling past the end fills the footer, and
/// letting go once it's full does the same, as a shortcut for a trackpad.
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
        // So a file shorter than the view can still be pulled past its end.
        scroll.verticalScrollElasticity = .allowed
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = coordinator.textView
        // In the clip view, the footer is placed in the document's coordinates and so scrolls
        // with it, clipped like the text.
        scroll.contentView.addSubview(coordinator.footer)
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
        coordinator.textView.onAnchorClick = onAnchorClick
        scroll.hasHorizontalScroller = !wrapLines
        coordinator.textView.wrapsLines = wrapLines
        if coordinator.shownPath != file.path {
            coordinator.shownPath = file.path
            coordinator.textView.show(RenderedDiff(file: file))
        }
        coordinator.footer.isHidden = review == nil
        coordinator.layoutFooter()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
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
        private var trigger = OverscrollTrigger()
        private weak var scroll: NSScrollView?
        private var observers: [any NSObjectProtocol] = []

        func observe(_ scroll: NSScrollView) {
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
        /// inset at the bottom only as far as the footer needs to be scrolled to.
        func layoutFooter() {
            guard let scroll else { return }
            let clip = scroll.contentView.bounds
            let top = contentBottom(clipHeight: clip.height)
            let frame = NSRect(x: clip.minX, y: top, width: clip.width, height: ReviewFooter.height)
            if footer.frame != frame { footer.frame = frame }
            let inset = review == nil ? 0 : max(0, frame.maxY - textView.frame.maxY)
            if scroll.contentInsets.bottom != inset {
                scroll.contentInsets.bottom = inset
                // The scrollers keep to the whole height, over the footer too.
                scroll.scrollerInsets.bottom = -inset
            }
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

        /// The fingers touching down to scroll, or lifting.
        func drag(began: Bool) {
            guard review != nil else { return }
            if began {
                trigger.beginDrag()
            } else if trigger.endDrag() == .fired {
                review?.markViewedAndAdvance()
            }
            show(trigger)
        }

        private func scrolled() {
            layoutFooter()
            guard let scroll, review != nil else { return }
            let clip = scroll.contentView.bounds
            // Where the bottom of the view rests when scrolled to the end, footer included.
            let end = max(textView.frame.maxY + scroll.contentInsets.bottom, clip.height)
            let overscroll = clip.maxY - end
            if trigger.scroll(overscroll: overscroll) == .armed {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            show(trigger)
        }

        private func show(_ trigger: OverscrollTrigger) {
            footerState.progress = trigger.progress
            footerState.isArmed = trigger.isArmed
        }
    }
}

/// Reports when the fingers touch down on the trackpad to scroll and when they lift, which
/// momentum scrolling afterwards doesn't count as.
private final class OverscrollScrollView: NSScrollView {
    var onDrag: (_ began: Bool) -> Void = { _ in }

    override func scrollWheel(with event: NSEvent) {
        if event.phase.contains(.began) { onDrag(true) }
        super.scrollWheel(with: event)
        if !event.phase.isDisjoint(with: [.ended, .cancelled]) { onDrag(false) }
    }
}

@Observable
@MainActor
final class ReviewFooterState {
    var progress: CGFloat = 0
    var isArmed = false
    var isViewed = false
    var label = ""
}

/// The end of a PR file's diff: a bar like the file's header, with a button that marks the file
/// reviewed and shows the next. Pulling past the end fills it from the left, turning green once
/// letting go will do the same.
struct ReviewFooter: View {
    static let height: CGFloat = 56

    let state: ReviewFooterState
    let action: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            ZStack {
                GeometryReader { geometry in
                    Rectangle()
                        .fill((state.isArmed ? Color.diffSuccess : Color.accentColor).opacity(state.isArmed ? 0.25 : 0.12))
                        .frame(width: geometry.size.width * state.progress)
                }
                Button(action: action) {
                    Label(state.label, systemImage: state.isArmed ? "checkmark.circle.fill" : state.isViewed ? "arrow.down.circle" : "checkmark.circle")
                        .padding(.horizontal, 6)
                }
                .controlSize(.large)
                .help("Or pull past the end of the diff (⌘↓)")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(.bar)
        .animation(.easeOut(duration: 0.12), value: state.isArmed)
    }
}
