import AppKit
import LoupeCore
import LoupeGit
import LoupeInbox
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Renders `window` as it looks on screen, title bar, toolbar and tab bar included. Drawn by the
/// app itself, so it needs no screen-recording permission. Web views draw in another process,
/// so each is asked for its own snapshot and drawn in over its place.
@MainActor
func snapshot(window: NSWindow) async -> NSImage {
    let image = NSImage(size: window.frame.size)
    for case let view? in [window.contentView?.superview, window.contentView] {
        guard let rep = render(view) else { continue }
        await drawWebViews(in: view, onto: rep)
        drawChildWindows(of: window, onto: rep)
        image.addRepresentation(rep)
        break
    }
    return image
}

/// The Debug menu, for seeing the app as an agent would.
struct DebugCommands: Commands {
    let windows: WindowManager

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Save Snapshot of Window…") { saveSnapshotOfKeyWindow() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Snapshot All Tabs to Desktop") {
                Task { await snapshotAllTabsToDesktop(windows) }
            }
        }
    }
}

/// With `LOUPE_SNAPSHOT_DIR` set, the app writes a PNG of the window with each item of its tab
/// strip shown once the lists have refreshed and each PR's diff is ready or has failed (or a time
/// limit passes), then quits.
@MainActor
enum SnapshotRun {
    static let directory = ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_DIR"].map {
        URL(filePath: $0, directoryHint: .isDirectory)
    }

    static func start(windows: WindowManager) {
        guard let directory else { return }
        let environment = ProcessInfo.processInfo.environment
        let tabs = windows.tabs
        let deadline = Date.now.addingTimeInterval(20)
        let started = Date.now
        Task {
            let lists = tabs.lists
            await wait(until: deadline) { !lists.isLoading && (lists.error != nil || (lists.lastRefreshed ?? .distantPast) >= started) }
            // A tab's content is made when it's first shown, so each is shown once, and its diff
            // asked for in case hidden content doesn't load it.
            let selected = tabs.selected
            for tab in tabs.tabs { windows.select(tab.id) }
            windows.select(selected)
            for tab in tabs.tabs { Task { await tab.load() } }
            await wait(until: deadline) { tabs.tabs.allSatisfy(\.phase.isSettled) }
            // LOUPE_SNAPSHOT_TAB picks each PR's section; a commit or file to show needs the files.
            if environment["LOUPE_SNAPSHOT_COMMIT"] != nil || environment["LOUPE_SNAPSHOT_FILE"] != nil || environment["LOUPE_SNAPSHOT_OPEN_COMMITS"] == "1" {
                for tab in tabs.tabs { tab.section = .files }
            } else if let section = environment["LOUPE_SNAPSHOT_TAB"].flatMap(ReviewSection.init(named:)) {
                for tab in tabs.tabs { tab.section = section }
            }
            // A conversation is shown once it's fetched and its web view has drawn it.
            let conversations = tabs.tabs.filter { $0.section == .conversation }
            await wait(until: deadline) {
                conversations.allSatisfy { $0.isConversationSettled && ConversationPage.existingPage(for: $0)?.isLoaded == true }
            }
            // LOUPE_SNAPSHOT_EDIT_DESCRIPTION=1 opens the description's editor on each of the
            // viewer's own PRs, fetching the description from GitHub as a click would.
            if environment["LOUPE_SNAPSHOT_EDIT_DESCRIPTION"] == "1" {
                for tab in tabs.tabs {
                    await tab.load()
                    guard tab.canEditDescription else { continue }
                    tab.section = .conversation
                    await tab.editDescription()
                }
            }
            // LOUPE_SNAPSHOT_COMMIT shows one commit's changes: its 1-based index, or an oid prefix.
            if let wanted = environment["LOUPE_SNAPSHOT_COMMIT"] {
                for tab in tabs.tabs {
                    guard case .ready(let review) = tab.phase, let commit = review.commits.picked(by: wanted) else { continue }
                    await tab.showCommit(commit.oid)
                }
            }
            // LOUPE_SNAPSHOT_FILE picks the first file whose path contains it, hidden ones after
            // the rest, to snapshot a given kind of file.
            if let wanted = environment["LOUPE_SNAPSHOT_FILE"] {
                for tab in tabs.tabs {
                    guard case .ready(let changes)? = tab.shownChanges else { continue }
                    if let file = changes.files.first(where: { $0.path.contains(wanted) }) {
                        tab.selectedFile = file.id
                    } else if let file = changes.hidden.first(where: { $0.path.contains(wanted) }) {
                        tab.selectedFile = file.id
                        await tab.diffHiddenFile(file.path)
                    }
                }
            }
            // LOUPE_SNAPSHOT_RENDERED=1 shows each shown markdown file rendered, once GitHub has
            // rendered it and its web view has loaded.
            if environment["LOUPE_SNAPSHOT_RENDERED"] == "1" {
                let rendered = tabs.tabs.filter { tab in
                    guard let file = tab.shownFile, let source = tab.markdownSource(of: file) else { return false }
                    tab.markdown.setRendered(true, path: file.path)
                    Task { await tab.renderMarkdown(source) }
                    return true
                }
                for tab in rendered { windows.select(tab.id) }
                windows.select(tabs.selected)
                await wait(until: .now.addingTimeInterval(20)) {
                    rendered.allSatisfy { tab in
                        guard let file = tab.shownFile, let source = tab.markdownSource(of: file) else { return true }
                        if case .failed = tab.markdown.rendering(of: source) { return true }
                        return MarkdownPage.existingPage(for: tab).map { $0.shown == source && $0.isLoaded } ?? false
                    }
                }
            }
            // LOUPE_SNAPSHOT_EXPAND=<n> clicks the up arrow on the nth hunk header (from 1) of each
            // shown diff, or the both-ways one where the gap is small; `all` reveals whole files.
            if let wanted = environment["LOUPE_SNAPSHOT_EXPAND"] {
                for tab in tabs.tabs {
                    guard let file = tab.shownFile else { continue }
                    await tab.readContext(of: file)
                    if wanted == "all" {
                        await revealWholeFile(file, in: tab)
                    } else if let hunk = Int(wanted) {
                        windows.select(tab.id)
                        if let window = windows.mainWindow { await clickExpandArrow(onHunk: hunk - 1, in: window) }
                    }
                }
                windows.select(tabs.selected)
                try? await Task.sleep(for: .milliseconds(1000))
                for tab in tabs.tabs {
                    guard let file = tab.shownFile else { continue }
                    print("\(file.path) now shows \(tab.expandedFile(file).hunks.map(\.header).joined(separator: " | "))")
                }
            }
            // Review threads come with the conversation, so a diff waits for it to show them.
            await wait(until: deadline) { tabs.tabs.allSatisfy(\.isConversationSettled) }
            // LOUPE_SNAPSHOT_OPEN_RESOLVED=1 opens every resolved thread, as clicking each would.
            if environment["LOUPE_SNAPSHOT_OPEN_RESOLVED"] == "1" {
                for tab in tabs.tabs {
                    tab.threadActivity.expanded.formUnion(tab.conversation?.threads.filter(\.isResolved).map(\.id) ?? [])
                }
            }
            // LOUPE_SNAPSHOT_REPLY=1 opens a reply on the first unresolved thread of each shown
            // file, as its Reply button would; nothing is typed or sent.
            if environment["LOUPE_SNAPSHOT_REPLY"] == "1" {
                for tab in tabs.tabs {
                    guard let file = tab.shownFile, let threads = tab.threads(on: tab.expandedFile(file)),
                          let thread = threads.anchored.flatMap(\.threads).first(where: { !$0.isResolved })
                    else { continue }
                    tab.startReply(to: thread)
                }
            }
            // LOUPE_SNAPSHOT_COMMENT=<line> hovers the row of that new line in each shown diff,
            // clicks the "+" that shows, as starting a comment would, then hovers it again, so
            // the snapshot has both. Nothing is typed or sent.
            if let line = environment["LOUPE_SNAPSHOT_COMMENT"].flatMap(Int.init) {
                for tab in tabs.tabs {
                    windows.select(tab.id)
                    try? await Task.sleep(for: .milliseconds(800))
                    guard let window = windows.mainWindow, hoverRow(ofNewLine: line, in: window) else { continue }
                    visibleDiff(in: window)?.commentButton.performClick(nil)
                    try? await Task.sleep(for: .milliseconds(800))
                    _ = hoverRow(ofNewLine: line, in: window)
                }
                windows.select(tabs.selected)
            }
            // LOUPE_SNAPSHOT_THREAD=<n> scrolls each shown diff to its nth block of threads (from
            // 1, in the order they come down the diff), once they've measured themselves.
            if let wanted = environment["LOUPE_SNAPSHOT_THREAD"].flatMap(Int.init) {
                for tab in tabs.tabs {
                    windows.select(tab.id)
                    try? await Task.sleep(for: .milliseconds(800))
                    if let window = windows.mainWindow { scrollToThreads(wanted - 1, in: window) }
                }
                windows.select(tabs.selected)
            }
            // LOUPE_SNAPSHOT_CLICK_FOOTER=1 clicks the footer's button at the end of each shown
            // diff, to see that a real click on it marks the file reviewed and moves on.
            if ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_CLICK_FOOTER"] == "1" {
                try? await Task.sleep(for: .milliseconds(500))
                printSelectedFiles(of: tabs, when: "before clicking")
                for tab in tabs.tabs {
                    windows.select(tab.id)
                    if let window = windows.mainWindow { await clickReviewFooter(in: window) }
                }
                windows.select(tabs.selected)
                try? await Task.sleep(for: .milliseconds(1500))
                printSelectedFiles(of: tabs, when: "after clicking")
            }
            // A moment for the final state to be drawn.
            try? await Task.sleep(for: .milliseconds(500))
            do {
                // LOUPE_SNAPSHOT_CLICK_TAB clicks a strip item (1-based, or "lists") first and
                // snapshots the result, to show that the strip takes clicks.
                if let wanted = environment["LOUPE_SNAPSHOT_CLICK_TAB"] {
                    print(try await saveSnapshotAfterClicking(wanted, in: windows, to: directory).path(percentEncoded: false))
                }
                // LOUPE_SNAPSHOT_OPEN_COMMITS=1 opens each PR's list of commits to pick from, once
                // they're counted, and snapshots it.
                if environment["LOUPE_SNAPSHOT_OPEN_COMMITS"] == "1" {
                    for url in try await saveSnapshotsOfCommitLists(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_SHOW_CHECKS=1 opens the checks popover on the lists' first glyph
                // and each PR's header, and snapshots it.
                if environment["LOUPE_SNAPSHOT_SHOW_CHECKS"] == "1" {
                    for url in try await saveSnapshotsOfChecks(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                for url in try await saveSnapshotsOfAllTabs(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
            } catch {
                FileHandle.standardError.write(Data("Couldn't write snapshots: \(error)\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }

    private static func wait(until deadline: Date, for isDone: () -> Bool) async {
        while Date.now < deadline, !isDone() {
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    private static func printSelectedFiles(of tabs: TabsModel, when: String) {
        for tab in tabs.tabs {
            print("\(when): selected \(tab.selectedFile.map { "\($0)" } ?? "none")")
        }
    }

    /// Scrolls the shown diff to its end, then clicks its footer's button through the window as
    /// the mouse would. The mouse-up is queued first, so a button's tracking loop finds it.
    private static func clickReviewFooter(in window: NSWindow) async {
        try? await Task.sleep(for: .milliseconds(300))
        guard let root = window.contentView,
              let footer = descendants(of: root).first(where: { $0 is NSHostingView<ReviewFooter> && !$0.isHiddenOrHasHiddenAncestor }),
              let document = footer.enclosingScrollView?.documentView
        else { return }
        document.scroll(NSPoint(x: 0, y: footer.frame.maxY))
        footer.scrollToVisible(footer.bounds)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        let point = footer.convert(NSPoint(x: footer.bounds.midX, y: footer.bounds.midY), to: nil)
        let frameView = root.superview ?? root
        let hit = frameView.hitTest(frameView.convert(point, from: nil))
        let chain = sequence(first: hit, next: { $0?.superview }).prefix(while: { $0 != nil }).compactMap { $0 }.prefix(8)
        print("clicking the footer at \(point) in the window hits \(chain.map { String(describing: type(of: $0)) }.joined(separator: " < "))")
        let events = [NSEvent.EventType.leftMouseUp, .leftMouseDown].compactMap { type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard events.count == 2 else { return }
        NSApp.postEvent(events[0], atStart: false)
        window.sendEvent(events[1])
    }

    /// Scrolls the shown diff so a hunk's header is a little way down the view, then clicks the
    /// arrow there that reveals lines above the hunk, through the window as the mouse would.
    private static func clickExpandArrow(onHunk hunk: Int, in window: NSWindow) async {
        try? await Task.sleep(for: .milliseconds(300))
        guard let root = window.contentView,
              let textView = descendants(of: root).lazy.compactMap({ $0 as? DiffTextView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
              let rendered = textView.rendered, rendered.hunkRows.indices.contains(hunk),
              let layoutManager = textView.layoutManager, let container = textView.textContainer
        else { return }
        let row = rendered.hunkRows[hunk]
        let end = row + 1 < rendered.rowStarts.count ? rendered.rowStarts[row + 1] : rendered.text.length
        var arrow: NSRange?
        rendered.text.enumerateAttribute(.diffExpansion, in: NSRange(location: rendered.rowStarts[row], length: end - rendered.rowStarts[row])) { value, range, stop in
            guard let expansion = value as? ContextExpansion, expansion.hunk == hunk, expansion.direction == .above else { return }
            arrow = range
            stop.pointee = true
        }
        guard let arrow else {
            print("hunk \(hunk + 1) has nothing hidden above it to reveal")
            return
        }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(arrow)))
        let bounds = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: arrow, actualCharacterRange: nil), in: container)
        let origin = textView.textContainerOrigin
        textView.scroll(NSPoint(x: 0, y: max(0, bounds.minY + origin.y - 120)))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        let point = textView.convert(NSPoint(x: bounds.midX + origin.x, y: bounds.midY + origin.y), to: nil)
        let glyph = (rendered.text.string as NSString).substring(with: arrow).trimmingCharacters(in: .whitespaces)
        let frameView = root.superview ?? root
        let hit = frameView.hitTest(frameView.convert(point, from: nil))
        print("clicking \(glyph) on hunk \(hunk + 1)'s header at \(point) in the window hits \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        window.sendEvent(event)
    }

    /// Scrolls the shown diff so its nth block of threads is a little way down the view,
    /// printing where each block's row is.
    private static func scrollToThreads(_ index: Int, in window: NSWindow) {
        guard let root = window.contentView,
              let textView = descendants(of: root).lazy.compactMap({ $0 as? DiffTextView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
              let rendered = textView.rendered, let layoutManager = textView.layoutManager
        else { return }
        let blocks = rendered.blockRows.sorted { $0.value < $1.value }
        print("thread blocks: \(blocks.map { "\($0.key) at row \($0.value)" }.joined(separator: ", "))")
        guard blocks.indices.contains(index), let range = rendered.range(ofBlock: blocks[index].key) else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
        textView.scroll(NSPoint(x: 0, y: max(0, fragment.minY + textView.textContainerOrigin.y - 100)))
    }

    /// Scrolls the shown diff so the row of a new line is a little way down, then moves the
    /// mouse over it as the pointer would, printing whether its "+" shows.
    private static func hoverRow(ofNewLine line: Int, in window: NSWindow) -> Bool {
        guard let textView = visibleDiff(in: window), let rendered = textView.rendered, let layoutManager = textView.layoutManager,
              let row = rendered.rowAnchors.firstIndex(where: { $0?.side == .right && $0?.line == line })
        else {
            print("no row for new line \(line) to hover")
            return false
        }
        let start = rendered.rowStarts[row]
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: start + 1))
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
        let top = fragment.minY + textView.textContainerOrigin.y
        textView.scroll(NSPoint(x: 0, y: max(0, top - 120)))
        window.layoutIfNeeded()
        let point = textView.convert(NSPoint(x: 300, y: top + fragment.height / 2), to: nil)
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return false }
        textView.mouseMoved(with: event)
        print("hovering new line \(line): the comment button is \(textView.commentButton.isHidden ? "hidden" : "shown")")
        return !textView.commentButton.isHidden
    }

    private static func visibleDiff(in window: NSWindow) -> DiffTextView? {
        guard let root = window.contentView else { return nil }
        return descendants(of: root).lazy.compactMap { $0 as? DiffTextView }.first { !$0.isHiddenOrHasHiddenAncestor }
    }

    /// Reveals every unchanged line of the file, closing each gap from the bottom up.
    private static func revealWholeFile(_ file: FileDiff, in tab: PullRequestTab) async {
        guard tab.expandableContext(of: file) != nil else { return }
        while tab.expandedFile(file).hunks.count > 1 {
            let before = tab.expandedFile(file).hunks.count
            await tab.expandContext(of: file, ContextExpansion(hunk: before - 1, direction: .above, lines: nil))
            if tab.expandedFile(file).hunks.count == before { return }
        }
        await tab.expandContext(of: file, ContextExpansion(hunk: 0, direction: .above, lines: nil))
        await tab.expandContext(of: file, ContextExpansion(hunk: 0, direction: .below, lines: nil))
    }
}

/// Writes the window to `directory` as `<index>-<title>.png` with each item of the tab strip shown
/// in turn, the lists first, and returns the files written.
@MainActor
func saveSnapshotsOfAllTabs(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for (index, id) in ([nil] + windows.tabs.tabs.map(\.id)).enumerated() {
        windows.select(id)
        let url = directory.appending(path: "\(index + 1)-\(sanitised(windows.title(of: id))).png")
        try await saveSnapshot(of: window, to: url)
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// Brings the window forward, without taking focus during a snapshot run, where the app must stay
/// behind whatever the user is doing.
@MainActor
func bringForward(_ window: NSWindow) {
    if SnapshotRun.directory != nil {
        window.orderBack(nil)
    } else {
        window.makeKeyAndOrderFront(nil)
    }
}

/// Clicks the strip item `wanted` names (1-based, or "lists") and writes the window as
/// `clicked-<title>.png`, titled by whatever the click showed.
@MainActor
private func saveSnapshotAfterClicking(_ wanted: String, in windows: WindowManager, to directory: URL) async throws -> URL {
    guard let window = windows.mainWindow, let position = wanted == "lists" ? 0 : Int(wanted),
          windows.clickStripItem(at: position)
    else { throw SnapshotError.noSuchTab(wanted) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "clicked-\(sanitised(windows.title(of: windows.tabs.selected))).png")
    try await saveSnapshot(of: window, to: url)
    return url
}

/// Opens each diffed PR's list of commits to pick from, once they're counted, and writes the
/// window with it open as `commits-<title>.png`.
@MainActor
private func saveSnapshotsOfCommitLists(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs {
        guard case .ready = tab.phase else { continue }
        await tab.countCommitChanges()
        windows.select(tab.id)
        try? await Task.sleep(for: .milliseconds(300))
        tab.isPickingCommit = true
        try? await Task.sleep(for: .milliseconds(300))
        if let root = window.contentView,
           let picker = descendants(of: root).first(where: { $0 is CommitPickerMarker.Marker && !$0.isHiddenOrHasHiddenAncestor }) {
            placePopover(under: picker, in: window)
        }
        let url = directory.appending(path: "commits-\(sanitised(windows.title(of: tab.id))).png")
        try await saveSnapshot(of: window, to: url)
        tab.isPickingCommit = false
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// Opens the checks popover on the topmost checks glyph of the lists and of each PR, and writes
/// the window with it open as `checks-<title>.png`.
@MainActor
private func saveSnapshotsOfChecks(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for id in [nil] + windows.tabs.tabs.map(\.id) {
        windows.select(id)
        try? await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        guard let root = window.contentView,
              let anchor = descendants(of: root).lazy.compactMap({ $0 as? ChecksPopoverAnchor.AnchorView })
                  .filter({ !$0.isHiddenOrHasHiddenAncestor })
                  .min(by: { readsBefore($0, $1) })
        else {
            print("\(windows.title(of: id)) shows no checks glyph")
            continue
        }
        anchor.showPopover()
        try? await Task.sleep(for: .milliseconds(300))
        placePopover(under: anchor, in: window)
        let url = directory.appending(path: "checks-\(sanitised(windows.title(of: id))).png")
        try await saveSnapshot(of: window, to: url)
        anchor.closePopover()
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// Lets the window settle and draw, then writes it to `url`.
@MainActor
private func saveSnapshot(of window: NSWindow, to url: URL) async throws {
    try? await Task.sleep(for: .milliseconds(300))
    window.layoutIfNeeded()
    window.displayIfNeeded()
    try pngData(await snapshot(window: window)).write(to: url)
}

private enum SnapshotError: Error, CustomStringConvertible {
    case noSuchTab(String)

    var description: String {
        switch self {
        case let .noSuchTab(wanted): "no tab strip item \(wanted) to click"
        }
    }
}

@MainActor
private func saveSnapshotOfKeyWindow() {
    guard let window = NSApp.keyWindow else { return }
    Task { saveSnapshot(await snapshot(window: window), of: window) }
}

@MainActor
private func saveSnapshot(_ image: NSImage, of window: NSWindow) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "\(sanitised(window.title)).png"
    panel.beginSheetModal(for: window) { response in
        guard response == .OK, let url = panel.url else { return }
        MainActor.assumeIsolated {
            do {
                try pngData(image).write(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

@MainActor
private func snapshotAllTabsToDesktop(_ windows: WindowManager) async {
    let stamp = Date.now.formatted(.iso8601.dateSeparator(.dash).timeSeparator(.omitted).timeZoneSeparator(.omitted))
    let directory = URL.desktopDirectory.appending(path: "Loupe Snapshots \(stamp)", directoryHint: .isDirectory)
    do {
        _ = try await saveSnapshotsOfAllTabs(in: windows, to: directory)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    } catch {
        NSAlert(error: error).runModal()
    }
}

/// Draws each visible web view under `root` onto `rep`, which holds `root` as drawn.
@MainActor
private func drawWebViews(in root: NSView, onto rep: NSBitmapImageRep) async {
    for webView in descendants(of: root).compactMap({ $0 as? WKWebView }) where !webView.isHiddenOrHasHiddenAncestor {
        guard let image = try? await webView.takeSnapshot(configuration: nil) else { continue }
        var rect = webView.convert(webView.bounds, to: root)
        if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Moves the open popover to just under `view`, as on screen. The window is off every screen
/// during a snapshot run, so AppKit has moved the popover onto one, away from it.
@MainActor
private func placePopover(under view: NSView, in window: NSWindow) {
    guard let popover = window.childWindows?.first(where: \.isVisible) else { return }
    let anchor = view.convert(view.bounds, to: nil)
    let x = min(max(anchor.midX - popover.frame.width / 2, 0), window.frame.width - popover.frame.width)
    popover.setFrameTopLeftPoint(NSPoint(x: window.frame.minX + x, y: window.frame.minY + anchor.minY))
}

/// Draws the content of `window`'s visible child windows, such as an open popover, over where
/// they sit on it onto `rep`, which holds the window as drawn. A popover's frame is a material
/// that doesn't draw off screen, so a plain rounded panel stands in for it.
@MainActor
private func drawChildWindows(of window: NSWindow, onto rep: NSBitmapImageRep) {
    for child in window.childWindows ?? [] where child.isVisible {
        guard let view = child.contentView, let image = render(view) else { continue }
        let inChild = view.convert(view.bounds, to: nil)
        let rect = inChild.offsetBy(dx: child.frame.minX - window.frame.minX, dy: child.frame.minY - window.frame.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let panel = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.setFill()
        panel.fill()
        NSColor.separatorColor.setStroke()
        panel.stroke()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Whether `view` reads before `other`: higher in the window, or level with it and to its left.
@MainActor
private func readsBefore(_ view: NSView, _ other: NSView) -> Bool {
    let (a, b) = (view.convert(view.bounds, to: nil), other.convert(other.bounds, to: nil))
    return abs(a.maxY - b.maxY) < 20 ? a.minX < b.minX : a.maxY > b.maxY
}

@MainActor
private func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
}

/// The view drawn at the window's backing scale, or nil if it draws nothing.
@MainActor
private func render(_ view: NSView) -> NSBitmapImageRep? {
    guard !view.bounds.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

@MainActor
private func pngData(_ image: NSImage) throws -> Data {
    guard let rep = image.representations.lazy.compactMap({ $0 as? NSBitmapImageRep }).first,
          let data = rep.representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    return data
}

/// `title` with anything but letters, digits and `-` replaced, safe as a file name.
private func sanitised(_ title: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
    let replaced = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    return replaced.isEmpty ? "window" : replaced
}

private extension [PullRequestCommit] {
    /// The commit `wanted` names: a 1-based index if it's a short number, else an oid prefix.
    func picked(by wanted: String) -> PullRequestCommit? {
        if wanted.count < 4, let index = Int(wanted) {
            return indices.contains(index - 1) ? self[index - 1] : nil
        }
        return first { $0.oid.hasPrefix(wanted) }
    }
}

private extension PullRequestTab {
    /// The selected file's diff in the shown changes, hidden or not, once diffed.
    var shownFile: FileDiff? {
        guard case let .ready(changes)? = shownChanges, let selectedFile else { return nil }
        if let file = changes.files.first(where: { $0.id == selectedFile }) { return file }
        if case let .ready(diff)? = hiddenFileDiff(of: selectedFile) { return diff }
        return nil
    }
}

private extension ReviewSection {
    /// The section `LOUPE_SNAPSHOT_TAB` names.
    init?(named name: String) {
        switch name {
        case "conversation": self = .conversation
        case "files": self = .files
        default: return nil
        }
    }
}

private extension ReviewPhase {
    /// Done, one way or another.
    var isSettled: Bool {
        switch self {
        case .ready, .failed, .noCheckout: true
        case .resolvingCheckout, .fetching, .diffing: false
        }
    }
}
