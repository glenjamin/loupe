import AppKit
import LoupeInbox
import SwiftUI
import UniformTypeIdentifiers

/// Renders `window` as it looks on screen, title bar, toolbar and tab bar included. Drawn by the
/// app itself, so it needs no screen-recording permission.
@MainActor
func snapshot(window: NSWindow) -> NSImage {
    let rep = [window.contentView?.superview, window.contentView].lazy.compactMap { $0.flatMap(render) }.first
    let image = NSImage(size: window.frame.size)
    if let rep { image.addRepresentation(rep) }
    return image
}

/// The Debug menu, for seeing the app as an agent would.
struct DebugCommands: Commands {
    var body: some Commands {
        CommandMenu("Debug") {
            Button("Save Snapshot of Window…") { saveSnapshotOfKeyWindow() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Snapshot All Windows to Desktop") {
                Task { await snapshotAllWindowsToDesktop() }
            }
        }
    }
}

/// With `LOUPE_SNAPSHOT_DIR` set, the app writes a PNG of each window there once the lists have
/// refreshed and each PR's diff is ready or has failed (or a time limit passes), then quits.
@MainActor
enum SnapshotRun {
    static let directory = ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_DIR"].map {
        URL(filePath: $0, directoryHint: .isDirectory)
    }

    static func start(tabs: TabsModel) {
        guard let directory else { return }
        let deadline = Date.now.addingTimeInterval(20)
        let started = Date.now
        Task {
            let lists = tabs.lists
            await wait(until: deadline) { !lists.isLoading && (lists.error != nil || (lists.lastRefreshed ?? .distantPast) >= started) }
            // Hidden tabs' views don't load their diffs, so they're asked for here.
            for tab in tabs.tabs { Task { await tab.load() } }
            await wait(until: deadline) { tabs.tabs.allSatisfy(\.phase.isSettled) }
            // A moment for the final state to be drawn.
            try? await Task.sleep(for: .milliseconds(500))
            do {
                for url in try await saveSnapshotsOfAllWindows(to: directory) { print(url.path(percentEncoded: false)) }
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
}

/// Writes each of the app's windows to `directory` as `<index>-<title>.png`, bringing each tab
/// forward in turn so it's drawn, and returns the files written.
@MainActor
func saveSnapshotsOfAllWindows(to directory: URL) async throws -> [URL] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let windows = appWindows()
    let selected = NSApp.keyWindow
    var written: [URL] = []
    for (index, window) in windows.enumerated() {
        window.tabGroup?.selectedWindow = window
        bringForward(window)
        try? await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        let url = directory.appending(path: "\(index + 1)-\(sanitised(window.title)).png")
        try pngData(snapshot(window: window)).write(to: url)
        written.append(url)
    }
    if let selected {
        selected.tabGroup?.selectedWindow = selected
        bringForward(selected)
    }
    return written
}

/// Brings the window's tab forward, without taking focus during a snapshot run, where the app
/// must stay behind whatever the user is doing.
@MainActor
func bringForward(_ window: NSWindow) {
    if SnapshotRun.directory != nil {
        window.orderBack(nil)
    } else {
        window.makeKeyAndOrderFront(nil)
    }
}

@MainActor
private func saveSnapshotOfKeyWindow() {
    guard let window = NSApp.keyWindow else { return }
    let image = snapshot(window: window)
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
private func snapshotAllWindowsToDesktop() async {
    let stamp = Date.now.formatted(.iso8601.dateSeparator(.dash).timeSeparator(.omitted).timeZoneSeparator(.omitted))
    let directory = URL.desktopDirectory.appending(path: "Loupe Snapshots \(stamp)", directoryHint: .isDirectory)
    do {
        _ = try await saveSnapshotsOfAllWindows(to: directory)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    } catch {
        NSAlert(error: error).runModal()
    }
}

/// The app's windows in tab order, then any outside the tab group.
@MainActor
private func appWindows() -> [NSWindow] {
    let windows = NSApp.windows.filter { $0.tabbingIdentifier == WindowTabs.tabbingIdentifier }
    let grouped = windows.first?.tabGroup?.windows ?? []
    return grouped + windows.filter { window in !grouped.contains { $0 === window } }
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

private extension ReviewPhase {
    /// Done, one way or another.
    var isSettled: Bool {
        switch self {
        case .ready, .failed, .noCheckout: true
        case .resolvingCheckout, .fetching, .diffing: false
        }
    }
}
