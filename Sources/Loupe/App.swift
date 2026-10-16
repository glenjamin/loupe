import AppKit
import LoupeCore
import LoupeInbox
import LoupeModel
import LoupeStore
import SwiftUI

/// One window with the PR lists and a tab per opened PR. The window is AppKit's, made by
/// `WindowManager`; SwiftUI provides only the menu bar.
struct LoupeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    private let windows: WindowManager

    init() {
        let windows = WindowManager(tabs: makeTabs())
        self.windows = windows
        NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { windows.restore() }
        }
    }

    var body: some Scene {
        // A scene that opens no window, to hang the menus on.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) {}
                TabCommands(windows: windows)
                DiffCommands()
                DebugCommands(windows: windows)
            }
    }
}

/// `Loupe <diff>`: one window showing a diff file.
struct DiffApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = ReviewModel.load(path: LaunchOptions.diffPath)

    var body: some Scene {
        WindowGroup(model.title) {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowToolbarStyle(.unified)
    }
}

/// Launched as a bare SwiftPM executable (no .app bundle), the process starts as a background
/// app and its window never takes keyboard focus unless it's promoted to a regular app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app's tabs are its own, so the Window menu offers no native window tabs.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        // Before any window shows, so a snapshot run is never activated by one.
        if SnapshotRun.directory != nil { NSApp.setActivationPolicy(.accessory) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A snapshot run stays out of the way: no Dock tile, and never the active app.
        guard SnapshotRun.directory == nil else { return }
        NSApp.setActivationPolicy(.regular)
        applyIcon()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The Dock tile may not exist yet when launch finishes, so the icon is set again here.
    func applicationDidBecomeActive(_ notification: Notification) {
        if SnapshotRun.directory != nil {
            // Opening windows can activate the app anyway; hand focus straight back.
            NSApp.deactivate()
            return
        }
        applyIcon()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Run as a bare executable there's no Info.plist icon, so the Dock and About panel take it
    /// from here; once the Dock tile exists, that is.
    @MainActor private func applyIcon() {
        if let icon = Self.icon { NSApp.applicationIconImage = icon }
    }

    @MainActor private static let icon = iconURL.flatMap(NSImage.init(contentsOf:))

    /// The .app has the icon in its own resources; `swift run` has it only in SwiftPM's bundle,
    /// whose accessor would look for it at the .app's root, where it can't go and stay signed.
    static let iconURL = Bundle.main.url(forResource: "Loupe", withExtension: "icns")
        ?? Bundle.module.url(forResource: "Loupe", withExtension: "icns")
}

@Observable
@MainActor
final class ReviewModel {
    let title: String
    let files: [FileDiff]
    let excludedCount: Int
    var selection: FileDiff.ID?
    var error: String?

    init(title: String, files: [FileDiff], excludedCount: Int, error: String? = nil) {
        self.title = title
        self.files = files
        self.excludedCount = excludedCount
        self.selection = FileTree(paths: files.map(\.path)).files.first
        self.error = error
    }

    static func load(path: String) -> ReviewModel {
        let title = (path as NSString).lastPathComponent
        do {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            let parts = PathFilter.default.partition(DiffParser.parse(text))
            return ReviewModel(title: title, files: parts.included, excludedCount: parts.excluded.count)
        } catch {
            return ReviewModel(title: title, files: [], excludedCount: 0, error: "\(error.localizedDescription)")
        }
    }

    var selectedFile: FileDiff? { files.first { $0.id == selection } }
}

struct ContentView: View {
    @Bindable var model: ReviewModel

    var body: some View {
        NavigationSplitView {
            FileList(files: model.files, hiddenCount: model.excludedCount, selection: $model.selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 300)
        } detail: {
            if let file = model.selectedFile {
                DiffView(file: file) { anchor in print("clicked \(anchor)") }
            } else {
                Text(model.error ?? "No file selected").foregroundStyle(.secondary)
            }
        }
    }
}

/// The files to review as a tree of their directories, with a count of those hidden as
/// vendored, lockfiles or generated.
struct FileList: View {
    let files: [FileDiff]
    let hiddenCount: Int
    @Binding var selection: FileDiff.ID?
    /// Directories folded shut; every one starts open.
    @State private var collapsed: Set<String> = []

    var body: some View {
        let byPath = Dictionary(files.map { ($0.path, $0) }) { first, _ in first }
        List(selection: $selection) {
            FileTreeRows(nodes: FileTree(paths: byPath.keys).nodes, tree: "files", collapsed: $collapsed) { path in
                if let file = byPath[path] {
                    FileRow(file: file).tag(Optional(path))
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Text("\(files.count) files · \(hiddenCount) vendored, lockfile or generated hidden")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
        }
    }
}

/// A file on one line: its name, then its line counts at the end, or what happened to it where
/// no lines were counted.
struct FileRow: View {
    let file: FileDiff

    var body: some View {
        HStack(spacing: 6) {
            FileName(path: file.path)
            Spacer(minLength: 4)
            ReviewLineCounts(file: file).fixedSize()
        }
        .help(file.path)
    }
}

/// A file's document symbol and name, on one line, cut short at the end when there isn't room.
struct FileName: View {
    let path: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc").foregroundStyle(.secondary)
            Text(verbatim: (path as NSString).lastPathComponent)
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }
}

/// `+A −D` in monospaced digits, additions green and deletions red.
struct LineCounts: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: "+\(additions)").foregroundStyle(.diffSuccess)
            Text(verbatim: "\u{2212}\(deletions)").foregroundStyle(.diffDanger)
        }
        .font(.caption.monospacedDigit())
    }
}

extension FileDiff.Change {
    /// What happened to the file, in a word.
    var summary: String {
        switch self {
        case .added: "added"
        case .deleted: "deleted"
        case .modified: "modified"
        case .renamed: "renamed"
        case .copied: "copied"
        }
    }
}

@MainActor private func makeTabs() -> TabsModel {
    let store = openStore()
    // The tabs take over opening PRs.
    let lists = PullRequestListModel(store: store) { _ in }
    return TabsModel(lists: lists, store: store)
}

/// The on-disk store, or a throwaway one if it can't be opened, so the PR list still works.
/// `LOUPE_DATABASE` points it elsewhere, such as for a snapshot run.
private func openStore() -> PullRequestStore {
    let url = ProcessInfo.processInfo.environment["LOUPE_DATABASE"].map { URL(filePath: $0) } ?? PullRequestStore.defaultURL
    do {
        return try PullRequestStore(url: url)
    } catch {
        FileHandle.standardError.write(Data("Couldn't open \(url.path(percentEncoded: false)), not keeping PRs between runs: \(error)\n".utf8))
        return try! PullRequestStore.inMemory()
    }
}
