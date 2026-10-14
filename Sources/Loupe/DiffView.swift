import AppKit
import LoupeCore
import SwiftUI

/// One file's diff under a header naming it, in a bordered box as on GitHub. Clicking a row
/// reports its comment anchor. A PR's file also has a "Viewed" checkbox, and pulling past the
/// end of the diff marks it viewed and moves on.
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
                Toggle("Viewed", isOn: Binding(get: { review.isViewed }, set: { _ in review.toggleViewed() }))
                    .toggleStyle(.checkbox)
                    .help("Mark this file viewed on GitHub (⇧V)")
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

/// A PR file's viewed state, and what pulling past the end of its diff does.
struct FileReview {
    let isViewed: Bool
    let toggleViewed: () -> Void
    /// Says what letting go past the end will do.
    let advanceLabel: String
    let markViewedAndAdvance: () -> Void
}

/// The diff's text in a scroll view. For a PR's file, pulling past the end reveals an indicator
/// that fills as the pull goes on, and letting go once it's full marks the file viewed and moves on.
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
        scroll.documentView = coordinator.textView
        scroll.addSubview(coordinator.indicator)
        scroll.onDrag = { [weak coordinator] began in coordinator?.drag(began: began) }
        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.observe(scroll)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.review = review
        coordinator.indicatorState.label = review?.advanceLabel ?? ""
        coordinator.textView.onAnchorClick = onAnchorClick
        scroll.hasHorizontalScroller = !wrapLines
        coordinator.textView.wrapsLines = wrapLines
        if coordinator.shownPath != file.path {
            coordinator.shownPath = file.path
            coordinator.textView.show(RenderedDiff(file: file))
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let textView = DiffTextView.make()
        var shownPath: String?
        var review: FileReview?
        let indicatorState = OverscrollIndicatorState()
        lazy var indicator: NSHostingView<OverscrollIndicator> = {
            let view = NSHostingView(rootView: OverscrollIndicator(state: indicatorState))
            view.sizingOptions = []
            view.isHidden = true
            return view
        }()
        private var trigger = OverscrollTrigger()
        private weak var scroll: NSScrollView?
        private var observer: (any NSObjectProtocol)?

        func observe(_ scroll: NSScrollView) {
            self.scroll = scroll
            observer = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.scrolled() }
            }
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
            guard let scroll, review != nil else { return }
            let clip = scroll.contentView
            let end = max(scroll.documentView?.frame.height ?? 0, clip.bounds.height)
            let overscroll = clip.bounds.maxY - end
            if trigger.scroll(overscroll: overscroll) == .armed {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            // The gap revealed below the end of the content, in the scroll view's coordinates.
            if overscroll > 0 {
                indicator.frame = scroll.convert(NSRect(x: clip.bounds.minX, y: end, width: clip.bounds.width, height: overscroll), from: clip)
            }
            indicator.isHidden = overscroll <= 0
            show(trigger)
        }

        private func show(_ trigger: OverscrollTrigger) {
            indicatorState.progress = trigger.progress
            indicatorState.isArmed = trigger.isArmed
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
final class OverscrollIndicatorState {
    var progress: CGFloat = 0
    var isArmed = false
    var label = ""
}

/// Below the end of the diff: an arrow in a ring that fills as the pull goes on, turning to a
/// check once letting go will mark the file viewed.
struct OverscrollIndicator: View {
    let state: OverscrollIndicatorState

    var body: some View {
        HStack(spacing: 8) {
            ZStack {
                Circle().stroke(Color.secondary.opacity(0.25), lineWidth: 2)
                Circle()
                    .trim(from: 0, to: state.progress)
                    .stroke(state.isArmed ? Color.diffSuccess : Color.secondary, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: state.isArmed ? "checkmark" : "arrow.down")
                    .font(.system(size: 10, weight: .bold))
            }
            .frame(width: 20, height: 20)
            Text(state.label)
                .font(.callout)
        }
        .foregroundStyle(state.isArmed ? Color.diffSuccess : Color.secondary)
        .animation(.easeOut(duration: 0.12), value: state.isArmed)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, 14)
        .clipped()
    }
}
