import AppKit
import LoupeCore
import SwiftUI

/// One file's diff under a header naming it, in a bordered box as on GitHub. Clicking a row
/// reports its comment anchor. A PR's file also has a "Reviewed" checkbox, and ends in a footer
/// that marks it reviewed and moves on. A PR's markdown file can be shown rendered instead, and
/// a hidden npm lockfile as its package changes. An image file shows its image, before any
/// threads; an SVG's only when asked, as it has a diff of its own.
/// With `expandable`, hunk headers have arrows that ask for more of the file around them.
/// `blocks` are views laid between rows, such as review threads.
struct DiffView: View {
    let file: FileDiff
    let onAnchorClick: (DiffAnchor) -> Void
    /// Whether its changes since a rebase couldn't be told apart from the rebase's.
    var isUnseparated = false
    var review: FileReview?
    var markdown: MarkdownPreview?
    var packageLock: PackageLockPreview?
    var image: ImagePreview?
    var expandable: ExpandableContext?
    var onExpand: (ContextExpansion) -> Void = { _ in }
    /// Hides the lines revealed in the file; nil while nothing is revealed.
    var onCollapse: (() -> Void)?
    var blocks: [DiffBlockContent] = []
    /// The rows that offer a "+" to start a comment on hover; none when nil.
    var commentable: Set<DiffAnchor>?
    /// Starts a comment on a row, or on the selected rows from the second anchor to the first.
    var onComment: (DiffAnchor, DiffAnchor?) -> Void = { _, _ in }
    /// The rows the comment being written is on.
    var commented: Set<DiffAnchor> = []
    /// Whether whitespace changes are hidden, offered in a PR's file header.
    var whitespace: WhitespaceToggle?

    var body: some View {
        VStack(spacing: 0) {
            FileHeader(file: file, isUnseparated: isUnseparated, review: review, markdown: markdown, packageLock: packageLock, image: image, onCollapse: onCollapse, whitespace: whitespace)
            Divider()
            if file.isWhitespaceOnly {
                // As github.com says of a file whose changes hiding whitespace leaves none of.
                Text("Whitespace-only changes")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                Divider()
            }
            if let failure = packageLock?.failure {
                Label("Couldn't compare the packages, so the diff shows: \(failure)", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(failure)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                Divider()
            }
            // A rendering covers the diff rather than replacing it, so the diff keeps its place.
            ZStack {
                DiffTextScrollView(
                    file: file, onAnchorClick: onAnchorClick, review: review, expandable: expandable, onExpand: onExpand, blocks: (image?.block).map { [$0] + blocks } ?? blocks,
                    commentable: commentable, onComment: onComment, commented: commented
                )
                if let markdown, markdown.isRendered {
                    RenderedMarkdownView(preview: markdown)
                }
                if let packageLock, packageLock.showsChanges {
                    PackageLockChangesView(preview: packageLock)
                }
                if let image, image.isSVG, image.isRendered {
                    ScrollView { ImageComparisonView(preview: image) }
                        .background(Color(nsColor: .textBackgroundColor))
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
    let isUnseparated: Bool
    let review: FileReview?
    let markdown: MarkdownPreview?
    let packageLock: PackageLockPreview?
    let image: ImagePreview?
    let onCollapse: (() -> Void)?
    let whitespace: WhitespaceToggle?

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
            if isUnseparated {
                UnseparatedBadge(label: "Couldn't separate from rebase")
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
            if let whitespace {
                Toggle("Hide whitespace", systemImage: "paragraphsign", isOn: Binding(get: { whitespace.hides }, set: { hides in
                    if hides != whitespace.hides { whitespace.toggle() }
                }))
                    .toggleStyle(HeaderIconToggleStyle())
                    .help("Leave changes to whitespace out of every file's diff in this PR, as github.com's Hide whitespace does; line counts still include them (⌃⌘H)")
            }
            if let markdown {
                Picker("Show", selection: Binding(get: { markdown.isRendered }, set: { markdown.setRendered($0) })) {
                    Text("Source").tag(false)
                    Text("Rendered").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Show the diff, or the file as GitHub renders it")
            }
            if let image, image.isSVG {
                Picker("Show", selection: Binding(get: { image.isRendered }, set: { image.setRendered($0) })) {
                    Text("Source").tag(false)
                    Text("Rendered").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Show the diff, or the image it draws")
            }
            if let packageLock, packageLock.failure == nil {
                Picker("Show", selection: Binding(get: { packageLock.showsRawDiff }, set: { packageLock.setShowsRawDiff($0) })) {
                    Text("Changes").tag(false)
                    Text("Raw diff").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
                .help("Show the packages added, removed, updated and moved, or the lockfile's diff")
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
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("file-header")
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

/// Whether a PR's diffs hide changes to whitespace, and how to turn it the other way.
struct WhitespaceToggle {
    let hides: Bool
    let toggle: () -> Void
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
    let onComment: (DiffAnchor, DiffAnchor?) -> Void
    let commented: Set<DiffAnchor>
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
        scroll.onPull = { [weak coordinator] event in coordinator?.pull(event) ?? false }
        scroll.currentPull = { [weak coordinator] in coordinator?.currentPull ?? OverscrollTrigger() }
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
        // A PR's diff moves past its end only as far as the pull reveals its strip, which the
        // rubber band would add to; a plain diff keeps the rubber band.
        scroll.verticalScrollElasticity = review == nil ? .allowed : .none
        coordinator.textView.wrapsLines = wrapLines
        // The same file shown anew, as when more of it is revealed, keeps the reader's place.
        let shown = ShownDiff(path: file.path, headers: file.hunks.map(\.header), expandable: expandable, blocks: blocks.map(\.id), ignoresWhitespace: file.ignoresWhitespace)
        if coordinator.shown != shown {
            let isSameFile = coordinator.shown?.path == file.path
            coordinator.shown = shown
            if !isSameFile { coordinator.dropPull() }
            let sized = blocks.map { DiffBlock(id: $0.id, placement: $0.placement, height: coordinator.blockHeights[$0.id] ?? Coordinator.estimatedBlockHeight) }
            coordinator.textView.show(RenderedDiff(file: file, expandable: expandable, blocks: sized), keepingPlace: isSameFile)
        }
        coordinator.showBlocks(blocks)
        coordinator.textView.commentedAnchors = commented
        if let block = blocks.first(where: { $0.reveal != nil }) {
            coordinator.reveal(block.id)
            // After this update, as it changes what the view is drawn from.
            DispatchQueue.main.async { block.reveal?() }
        }
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
        /// The block last brought into view, kept there until a moment has passed.
        private var revealing: (id: String, until: Date)?
        private var trigger = OverscrollTrigger()
        /// How far below the footer the view can scroll for the pull, as extra bottom inset: the
        /// strip it has revealed while the fingers are down, kept while it settles back.
        private var pullInset: CGFloat = 0
        /// Counts settles, so one that's been overtaken doesn't end the next.
        private var settles = 0
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

        /// Scrolls the block into view, and again as blocks measure themselves for a moment
        /// after, as each one above it that does moves it.
        func reveal(_ id: String) {
            revealing = (id, .now.addingTimeInterval(1))
            textView.scrollToBlock(id)
        }

        private func blockMeasured(_ height: CGFloat, id: String) {
            let height = ceil(height)
            guard height > 0, blockViews[id] != nil, blockHeights[id] != height else { return }
            blockHeights[id] = height
            textView.setHeight(height, ofBlock: id)
            if let revealing, Date.now < revealing.until { textView.scrollToBlock(revealing.id) }
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
        /// pull's strip below the end, out of view until the pull adds to the inset.
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
            let inset = review == nil ? 0 : max(0, frame.maxY - textView.frame.maxY) + pullInset
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

        /// Returns true when the pull moved the view, so AppKit mustn't scroll it as well.
        func pull(_ event: PullEvent) -> Bool {
            guard review != nil else { return false }
            var moved = false
            switch event {
            case .began:
                stopSettling()
                trigger.beginDrag(atEnd: isAtEnd)
            case .moved(let distance, let time):
                // The view's bounds say where the end is only until the fingers are past it; from
                // then until they're back the pull's travel says, and the pull moves the view.
                let wasPast = trigger.travel > 0
                guard trigger.isDragging, wasPast || isAtEnd else { break }
                if trigger.pull(by: distance, at: time) {
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
                }
                // Going back from the end at rest is the document's own scrolling.
                moved = wasPast || distance > 0
                if moved { reveal(trigger.revealed) }
            case .ended:
                // Settles back even when it fires, as the next file comes only once it's marked.
                let fires = trigger.endDrag()
                settle()
                if fires { firePull() }
            case .cancelled:
                trigger.cancelDrag()
                settle()
            }
            showPull()
            return moved
        }

        var currentPull: OverscrollTrigger { trigger }

        /// Lets go of any pull at once, for a file about to be replaced.
        func dropPull() {
            trigger.cancelDrag()
            stopSettling()
            showPull()
        }

        private func showPull() {
            footerState.progress = trigger.progress
            footerState.isArmed = trigger.isArmed
            footerState.isPulling = trigger.isDragging
        }

        /// Grows the bottom inset by what the pull reveals and scrolls to the new end, so the view
        /// is held there by AppKit's own scrolling rather than against it.
        private func reveal(_ revealed: CGFloat) {
            pullInset = revealed
            layoutFooter()
            guard let scroll, let clip else { return }
            clip.scroll(to: NSPoint(x: clip.bounds.minX, y: endOrigin(of: clip)))
            scroll.reflectScrolledClipView(clip)
        }

        /// Animates back to the end without the pull's inset, as the content springs back once a
        /// pull lets go, and drops the inset once there.
        private func settle() {
            guard pullInset > 0, let clip else { return }
            settles += 1
            let settle = settles
            let end = endOrigin(of: clip) - pullInset
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.minX, y: end))
            } completionHandler: { [weak self] in
                Task { @MainActor in
                    guard let self, self.settles == settle else { return }
                    self.dropInset()
                }
            }
        }

        /// Ends a settle, or a pull, where it is and drops its inset at once, so it doesn't
        /// fight a new pull or a new document.
        private func stopSettling() {
            guard pullInset > 0, let clip else { return }
            settles += 1
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0
                clip.animator().setBoundsOrigin(clip.bounds.origin)
            }
            dropInset()
        }

        private func dropInset() {
            pullInset = 0
            layoutFooter()
            guard let scroll, let clip else { return }
            clip.scroll(to: clip.bounds.origin)
            scroll.reflectScrolledClipView(clip)
        }

        /// Marks the file reviewed and moves on, as the footer's button does; a snapshot run
        /// rehearsing pulls only says so, so nothing is written to GitHub.
        private func firePull() {
            if SnapshotRun.isRehearsingPulls {
                print("pull fired: markViewedAndAdvance")
                return
            }
            review?.markViewedAndAdvance()
        }

        /// The origin at the end of the document, insets included, as far as AppKit scrolls.
        private func endOrigin(of clip: NSClipView) -> CGFloat {
            let far = NSRect(x: clip.bounds.minX, y: clip.documentRect.maxY + clip.contentInsets.bottom, width: clip.bounds.width, height: clip.bounds.height)
            return clip.constrainBoundsRect(far).minY
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
    /// The fingers moved this far: positive pulls the content further past the end, negative
    /// back, at the event's timestamp.
    case moved(CGFloat, at: TimeInterval)
    case ended
    case cancelled
}

/// Reports a live trackpad drag's touch down, travel and lift to the pull, and leaves the
/// scrolling to AppKit except where the pull moved the view itself.
final class OverscrollScrollView: NSScrollView {
    /// Returns true when the pull moved the view for the event, so it isn't scrolled again.
    var onPull: (PullEvent) -> Bool = { _ in false }
    /// Where the pull stands, for a snapshot run to report.
    var currentPull: () -> OverscrollTrigger = { OverscrollTrigger() }
    /// Whether the drag's last move was the pull's, so the momentum after it is dropped rather
    /// than flinging the document while the pull settles back.
    private var pulledLast = false
    private var dropsMomentum = false

    override func scrollWheel(with event: NSEvent) {
        let phase = event.phase
        if phase.contains(.began) {
            dropsMomentum = false
            pulledLast = false
            _ = onPull(.began)
        }
        if !event.momentumPhase.isEmpty, dropsMomentum {
            if event.momentumPhase.contains(.ended) { dropsMomentum = false }
            return
        }
        // Asked before the event scrolls, so travel spent reaching the end doesn't count. The
        // delta already follows the content, natural scrolling or not; negative moves it up.
        if !phase.isDisjoint(with: [.began, .changed]), event.hasPreciseScrollingDeltas {
            pulledLast = onPull(.moved(-event.scrollingDeltaY, at: event.timestamp))
            if pulledLast { return }
        }
        super.scrollWheel(with: event)
        if phase.contains(.ended) {
            dropsMomentum = pulledLast
            _ = onPull(.ended)
        }
        if phase.contains(.cancelled) { _ = onPull(.cancelled) }
    }
}

/// A clip view whose clicks also reach the views placed beside its document, such as the footer
/// below the last row. A plain clip view hit-tests only within its document view's frame.
final class FooterClipView: NSClipView {
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
                    .lineLimit(1)
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
    /// Ignoring whitespace can turn changed lines into unchanged ones under the same headers.
    let ignoresWhitespace: Bool
}

/// A view to lay between a diff's rows, such as the review threads on a line. Its id names it
/// across updates and says where it goes, so a block that moves takes a new id.
struct DiffBlockContent {
    let id: String
    let placement: DiffBlock.Placement
    let view: AnyView
    /// Set to bring the block into view: the diff scrolls to it, then calls this, so it's done
    /// once.
    var reveal: (() -> Void)?
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

/// An icon toggle like a toolbar's: a plain secondary glyph while off, tinted under the pointer,
/// and filled while on, in grey in an inactive window as a selected row is, so on still stands out.
private struct HeaderIconToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HeaderIconToggle(configuration: configuration)
    }
}

private struct HeaderIconToggle: View {
    let configuration: ToggleStyleConfiguration
    @Environment(\.controlActiveState) private var activeState
    @State private var isHovered = false

    var body: some View {
        Button { configuration.isOn.toggle() } label: { configuration.label }
            .buttonStyle(HeaderIconButtonStyle(isOn: configuration.isOn, isActive: activeState != .inactive, isHovered: isHovered))
            .onHover { isHovered = $0 }
    }
}

private struct HeaderIconButtonStyle: ButtonStyle {
    let isOn: Bool
    let isActive: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(glyph)
            .frame(width: 22, height: 16)
            .background(fill(isPressed: configuration.isPressed), in: RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
    }

    private var glyph: AnyShapeStyle {
        guard isOn else { return isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary) }
        return AnyShapeStyle(.white)
    }

    private func fill(isPressed: Bool) -> AnyShapeStyle {
        guard isOn else { return isPressed ? AnyShapeStyle(.tertiary) : isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear) }
        let fill = isActive ? Color.accentColor : Color(nsColor: .systemGray)
        return AnyShapeStyle(fill.opacity(isPressed ? 0.75 : 1))
    }
}
