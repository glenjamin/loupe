import AppKit
import LoupeCore
import SwiftUI

/// One file's diff under a header naming it, in a bordered box as on GitHub. Clicking a row
/// reports its comment anchor. A PR's file also has a "Reviewed" checkbox, and ends in a footer
/// that marks it reviewed and moves on. A PR's markdown file can be shown rendered instead.
/// With `expandable`, hunk headers have arrows that ask for more of the file around them.
/// `blocks` are views laid between rows, such as review threads.
struct DiffView: View {
    let file: FileDiff
    let onAnchorClick: (DiffAnchor) -> Void
    var review: FileReview?
    var markdown: MarkdownPreview?
    var expandable: ExpandableContext?
    var onExpand: (ContextExpansion) -> Void = { _ in }
    /// Hides the lines revealed in the file; nil while nothing is revealed.
    var onCollapse: (() -> Void)?
    var blocks: [DiffBlockContent] = []
    /// The rows that offer a "+" to start a comment on hover; none when nil.
    var commentable: Set<DiffAnchor>?
    var onComment: (DiffAnchor) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            FileHeader(file: file, review: review, markdown: markdown, onCollapse: onCollapse)
            Divider()
            // The rendering covers the diff rather than replacing it, so the diff keeps its place.
            ZStack {
                DiffTextScrollView(
                    file: file, onAnchorClick: onAnchorClick, review: review, expandable: expandable, onExpand: onExpand, blocks: blocks,
                    commentable: commentable, onComment: onComment
                )
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
    let onCollapse: (() -> Void)?

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
            if let onCollapse {
                Button("Hide Revealed Lines", systemImage: "arrow.down.right.and.arrow.up.left", action: onCollapse)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Hide the revealed lines")
            }
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
                // Checking it is finishing the file, so it moves on like the footer; unchecking stays.
                Toggle("Reviewed", isOn: Binding(get: { review.isViewed }, set: { viewed in
                    if viewed { review.markViewedAndAdvance() } else { review.toggleViewed() }
                }))
                    .toggleStyle(.checkbox)
                    .help("Mark this file reviewed on GitHub and show the next unreviewed file (⇧V toggles it without moving on)")
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
    /// In the strip the pull reveals below the end, saying what letting the pull fire will do.
    let pullHint: String
    let markViewedAndAdvance: () -> Void
}

/// The diff's text in a scroll view. A PR's file ends in a footer, inside the scrolled content,
/// whose button marks the file reviewed and moves on. Pulling past the footer on a trackpad, like
/// pull-to-refresh, reveals a strip below it, then fills the button and does the same when let go
/// far enough.
private struct DiffTextScrollView: NSViewRepresentable {
    let file: FileDiff
    let onAnchorClick: (DiffAnchor) -> Void
    let review: FileReview?
    let expandable: ExpandableContext?
    let onExpand: (ContextExpansion) -> Void
    let blocks: [DiffBlockContent]
    let commentable: Set<DiffAnchor>?
    let onComment: (DiffAnchor) -> Void
    @AppStorage(DiffSettings.wrapLinesKey) var wrapLines = DiffSettings.wrapLinesDefault

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let scroll = OverscrollScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        let clip = FooterClipView()
        scroll.contentView = clip
        scroll.documentView = coordinator.textView
        // In the clip view, the footer is placed in the document's coordinates and so scrolls
        // with it, clipped like the text.
        scroll.contentView.addSubview(coordinator.footer)
        scroll.contentView.addSubview(coordinator.hint)
        scroll.isAtEnd = { [weak coordinator] in coordinator?.isAtEnd ?? false }
        scroll.onPull = { [weak coordinator] event in coordinator?.pull(event) }
        scroll.contentView.postsBoundsChangedNotifications = true
        coordinator.textView.postsFrameChangedNotifications = true
        coordinator.observe(scroll, clip: clip)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.review = review
        coordinator.footerState.label = review?.advanceLabel ?? ""
        coordinator.footerState.isViewed = review?.isViewed ?? false
        coordinator.footerState.pullHint = review?.pullHint ?? ""
        coordinator.textView.onAnchorClick = onAnchorClick
        coordinator.textView.onExpand = onExpand
        coordinator.textView.commentableAnchors = commentable
        coordinator.textView.onComment = onComment
        scroll.hasHorizontalScroller = !wrapLines
        // A PR's diff moves past its end only as far as the pull reveals its strip; a plain diff
        // keeps the rubber band.
        scroll.verticalScrollElasticity = review == nil ? .allowed : .none
        coordinator.textView.wrapsLines = wrapLines
        // The same file shown anew, as when more of it is revealed, keeps the reader's place.
        let shown = ShownDiff(path: file.path, headers: file.hunks.map(\.header), expandable: expandable, blocks: blocks.map(\.id))
        if coordinator.shown != shown {
            let isSameFile = coordinator.shown?.path == file.path
            coordinator.shown = shown
            if !isSameFile { coordinator.dropPull() }
            let sized = blocks.map { DiffBlock(id: $0.id, placement: $0.placement, height: coordinator.blockHeights[$0.id] ?? Coordinator.estimatedBlockHeight) }
            coordinator.textView.show(RenderedDiff(file: file, expandable: expandable, blocks: sized), keepingPlace: isSameFile)
        }
        coordinator.showBlocks(blocks)
        coordinator.footer.isHidden = review == nil
        coordinator.hint.isHidden = review == nil
        coordinator.layoutFooter()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        let textView = DiffTextView.make()
        var shown: ShownDiff?
        var review: FileReview?
        let footerState = ReviewFooterState()
        lazy var footer: NSHostingView<ReviewFooter> = {
            let view = NSHostingView(rootView: ReviewFooter(state: footerState) { [weak self] in
                self?.review?.markViewedAndAdvance()
            })
            view.sizingOptions = []
            return view
        }()
        /// Says what the pull will do, in the strip below the end that only the pull brings into
        /// view.
        lazy var hint: PullHintView = {
            let view = PullHintView(rootView: PullHint(state: footerState))
            view.sizingOptions = []
            return view
        }()
        /// How tall a block is taken to be until its view has measured itself.
        static let estimatedBlockHeight: CGFloat = 80

        /// Each block's height as its view last measured itself, so showing it again starts right.
        var blockHeights: [String: CGFloat] = [:]
        private var blockViews: [String: NSHostingView<DiffBlockRoot>] = [:]
        private var trigger = OverscrollTrigger()
        private weak var scroll: NSScrollView?
        private weak var clip: FooterClipView?
        private var observers: [any NSObjectProtocol] = []

        /// Lays each block's view over the row held for it, reusing the view a block had, so
        /// what's open in it stays open.
        func showBlocks(_ blocks: [DiffBlockContent]) {
            var views: [String: NSHostingView<DiffBlockRoot>] = [:]
            for block in blocks {
                let id = block.id
                let root = DiffBlockRoot(content: block.view) { [weak self] height in
                    // Measured while SwiftUI lays the view out, so the row changes after.
                    DispatchQueue.main.async { self?.blockMeasured(height, id: id) }
                }
                if let view = blockViews[id] {
                    view.rootView = root
                    views[id] = view
                } else {
                    let view = NSHostingView(rootView: root)
                    view.sizingOptions = []
                    views[id] = view
                }
            }
            blockViews = views
            textView.setBlockViews(views)
            layoutFooter()
        }

        private func blockMeasured(_ height: CGFloat, id: String) {
            let height = ceil(height)
            guard height > 0, blockViews[id] != nil, blockHeights[id] != height else { return }
            blockHeights[id] = height
            textView.setHeight(height, ofBlock: id)
            layoutFooter()
        }

        func observe(_ scroll: NSScrollView, clip: FooterClipView) {
            self.scroll = scroll
            self.clip = clip
            let center = NotificationCenter.default
            observers = [
                center.addObserver(forName: NSView.boundsDidChangeNotification, object: scroll.contentView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.textView.layoutBlocks()
                        self?.layoutFooter()
                    }
                },
                center.addObserver(forName: NSView.frameDidChangeNotification, object: textView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.textView.layoutBlocks()
                        self?.layoutFooter()
                    }
                },
            ]
        }

        /// Directly below the last row, across the visible width, so a short file has it
        /// straight after its content rather than at the bottom of the view. The content is
        /// inset at the bottom only as far as the footer needs to be scrolled to, leaving the
        /// pull's strip below the end, out of view until pulled.
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
            let strip = NSRect(x: clip.minX, y: restingEnd(clipHeight: clip.height), width: clip.width, height: OverscrollTrigger.leadIn)
            if hint.frame != strip { hint.frame = strip }
            let inset = review == nil ? 0 : max(0, frame.maxY - textView.frame.maxY)
            if scroll.contentInsets.bottom != inset {
                scroll.contentInsets.bottom = inset
                // The scrollers keep to the whole height, over the footer too.
                scroll.scrollerInsets.bottom = -inset
            }
        }

        /// Whether the view is scrolled to its end, footer fully shown, or pulled past it.
        var isAtEnd: Bool {
            guard let clip = scroll?.contentView.bounds else { return false }
            return clip.maxY >= restingEnd(clipHeight: clip.height) - 1
        }

        func pull(_ event: PullEvent) {
            guard review != nil else { return }
            switch event {
            case .began(let atEnd):
                trigger.beginDrag(atEnd: atEnd)
            case .moved(let distance, let time):
                if trigger.pull(by: distance, at: time) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                clip?.hold(pastEnd: trigger.revealed)
            case .leftEnd:
                trigger.leaveEnd()
                clip?.hold(pastEnd: 0)
            case .ended:
                // Settles back even when it fires, as the next file comes only once it's marked.
                clip?.settle()
                if trigger.endDrag() { review?.markViewedAndAdvance() }
            case .cancelled:
                clip?.settle()
                trigger.cancelDrag()
            }
            showPull()
        }

        /// Lets go of any pull at once, for a file about to be replaced.
        func dropPull() {
            trigger.cancelDrag()
            clip?.drop()
            showPull()
        }

        private func showPull() {
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
    /// The fingers touched down, with the view at its end or not.
    case began(atEnd: Bool)
    /// The fingers moved this far with the view at its end: positive pulls the content further
    /// past it, negative back, at the event's timestamp.
    case moved(CGFloat, at: TimeInterval)
    /// The fingers moved with the view back in the document, away from its end.
    case leftEnd
    case ended
    case cancelled
}

/// Reports a live trackpad drag's touch down, its travel while the view is at its end or leaving
/// it, and its lift, leaving the scrolling to AppKit.
final class OverscrollScrollView: NSScrollView {
    var isAtEnd: () -> Bool = { false }
    var onPull: (PullEvent) -> Void = { _ in }

    override func scrollWheel(with event: NSEvent) {
        let phase = event.phase
        if phase.contains(.began) { onPull(.began(atEnd: isAtEnd())) }
        // Checked before the event scrolls, so travel spent reaching the end doesn't count. The
        // delta already follows the content, natural scrolling or not; negative moves it up.
        if !phase.isDisjoint(with: [.began, .changed]), event.hasPreciseScrollingDeltas {
            onPull(isAtEnd() ? .moved(-event.scrollingDeltaY, at: event.timestamp) : .leftEnd)
        }
        super.scrollWheel(with: event)
        if phase.contains(.ended) { onPull(.ended) }
        if phase.contains(.cancelled) { onPull(.cancelled) }
    }

    /// Scrolls to the end and pulls `travel` past it from there, without events, so a snapshot
    /// can show the pull; `letGo()` lets go without firing.
    func showPull(_ travel: CGFloat) {
        contentView.scroll(to: NSPoint(x: contentView.bounds.minX, y: contentView.documentRect.maxY + contentInsets.bottom))
        reflectScrolledClipView(contentView)
        onPull(.began(atEnd: true))
        onPull(.moved(travel, at: ProcessInfo.processInfo.systemUptime))
    }

    func letGo() {
        onPull(.cancelled)
    }
}

/// A clip view whose clicks also reach the views placed beside its document, such as the footer
/// below the last row. A plain clip view hit-tests only within its document view's frame. It can
/// also be held past the end of its document, which AppKit won't scroll to, to reveal what's
/// placed below it, the way pull-to-refresh moves the content with the fingers.
final class FooterClipView: NSClipView {
    /// How far past the end the pull holds the view, wherever AppKit tries to scroll it there.
    private var heldPastEnd: CGFloat = 0
    /// How far past the end the view may still be while it settles back after a pull.
    private var settling: CGFloat = 0
    /// Counts settles, so one that's been overtaken doesn't end the next.
    private var settles = 0

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard bounds.contains(local) else { return nil }
        for view in subviews.reversed() where view !== documentView && !view.isHidden {
            if let hit = view.hitTest(local) { return hit }
        }
        return super.hitTest(point)
    }

    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard heldPastEnd > 0 || settling > 0 else { return rect }
        let end = endOrigin(height: proposedBounds.height)
        if heldPastEnd > 0, proposedBounds.minY >= end {
            rect.origin.y = end + heldPastEnd
        } else if proposedBounds.minY > end {
            rect.origin.y = min(proposedBounds.minY, end + settling)
        }
        return rect
    }

    /// Holds the view `offset` past the end of the document, or at zero gives it back to AppKit,
    /// where the drag that pulled back carries on scrolling it.
    func hold(pastEnd offset: CGFloat) {
        stopSettling()
        heldPastEnd = offset
        guard offset > 0 else { return }
        scroll(to: NSPoint(x: bounds.minX, y: endOrigin(height: bounds.height) + offset))
        enclosingScrollView?.reflectScrolledClipView(self)
    }

    /// Animates back to the end from past it, as the content springs back once a pull lets go.
    func settle() {
        let end = endOrigin(height: bounds.height)
        heldPastEnd = 0
        guard bounds.minY > end else { return }
        settling = bounds.minY - end
        settles += 1
        let settle = settles
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setBoundsOrigin(NSPoint(x: bounds.minX, y: end))
        } completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.settles == settle else { return }
                self.settling = 0
                self.enclosingScrollView?.reflectScrolledClipView(self)
            }
        }
    }

    /// Back within the document at once, for a document about to be replaced.
    func drop() {
        stopSettling()
        heldPastEnd = 0
        scroll(to: bounds.origin)
        enclosingScrollView?.reflectScrolledClipView(self)
    }

    /// Ends a settle where it is, so it doesn't fight a new pull or a new document.
    private func stopSettling() {
        guard settling > 0 else { return }
        settles += 1
        settling = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            animator().setBoundsOrigin(bounds.origin)
        }
    }

    /// The origin at the end of the document, as far as AppKit scrolls.
    private func endOrigin(height: CGFloat) -> CGFloat {
        let far = NSRect(x: bounds.minX, y: documentRect.maxY + contentInsets.bottom, width: bounds.width, height: height)
        return super.constrainBoundsRect(far).minY
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
        // Follows the fingers exactly, and empties smoothly as the content settles back.
        .animation(state.isPulling ? nil : .easeOut(duration: 0.25), value: state.progress)
    }
}

/// A caption in the strip below the end, like pull-to-refresh's, which only the pull brings into
/// view, saying what letting go will do once armed. It fades as the fingers lift.
struct PullHint: View {
    let state: ReviewFooterState

    var body: some View {
        // Armed, the same hint says what letting go does, as pull-to-refresh's "Release to refresh".
        Text(state.isArmed && state.pullHint.hasPrefix("Pull ") ? "Release " + state.pullHint.dropFirst("Pull ".count) : state.pullHint)
            .font(.callout)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .opacity(state.isPulling ? 1 : 0)
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

/// What a diff's text view was last given to show. Hunk headers change whenever revealing
/// lines changes the hunks, so they tell a new rendering of the file from the same one.
private struct ShownDiff: Equatable {
    let path: String
    let headers: [String]
    let expandable: ExpandableContext?
    /// The ids of the blocks laid between rows, which say where each goes.
    let blocks: [String]
}

/// A view to lay between a diff's rows, such as the review threads on a line. Its id names it
/// across updates and says where it goes, so a block that moves takes a new id.
struct DiffBlockContent {
    let id: String
    let placement: DiffBlock.Placement
    let view: AnyView
}

/// A block's view, at its natural height for the width it's given, reporting that height so
/// the row under it can be made to match.
struct DiffBlockRoot: View {
    let content: AnyView
    let onHeight: (CGFloat) -> Void

    var body: some View {
        content
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { geometry in
                Color.clear.preference(key: BlockHeightKey.self, value: geometry.size.height)
            })
            .onPreferenceChange(BlockHeightKey.self) { height in onHeight(height) }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct BlockHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
