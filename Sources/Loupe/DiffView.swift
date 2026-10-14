import AppKit
import LoupeCore
import SwiftUI

/// One file's diff in a scrolling DiffTextView. Clicking a row reports its comment anchor.
struct DiffView: NSViewRepresentable {
    let file: FileDiff
    let onAnchorClick: (DiffAnchor) -> Void
    @AppStorage(DiffSettings.wrapLinesKey) var wrapLines = DiffSettings.wrapLinesDefault

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = context.coordinator.textView
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
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
    }
}
