import AppKit
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
            if environment["LOUPE_SNAPSHOT_COMMIT"] != nil || environment["LOUPE_SNAPSHOT_FILE"] != nil {
                for tab in tabs.tabs { tab.section = .files }
            } else if let section = environment["LOUPE_SNAPSHOT_TAB"].flatMap(ReviewSection.init(named:)) {
                for tab in tabs.tabs { tab.section = section }
            }
            // A conversation is shown once it's fetched and its web view has drawn it.
            let conversations = tabs.tabs.filter { $0.section == .conversation }
            await wait(until: deadline) {
                conversations.allSatisfy { $0.isConversationSettled && ConversationPage.existingPage(for: $0)?.isLoaded == true }
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
