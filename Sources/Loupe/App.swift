import AppKit
import LoupeCore
import LoupeInbox
import LoupeStore
import SwiftUI

/// The PR lists in one window and each opened PR in its own, all grouped as native window tabs.
struct LoupeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var windowTabs = WindowTabs(tabs: makeTabs())

    var body: some Scene {
        Window("Pull Requests", id: WindowTabs.listsID) {
            ListsWindow(windowTabs: windowTabs)
                .frame(minWidth: 900, minHeight: 500)
        }
        .windowToolbarStyle(.unified)
        .commands {
            TabCommands()
            DiffCommands()
            DebugCommands()
        }
        WindowGroup("Pull Request", for: String.self) { $id in
            PullRequestWindow(id: id, windowTabs: windowTabs)
                .frame(minWidth: 900, minHeight: 500)
        }
        .windowToolbarStyle(.unified)
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
    /// The app's windows group as native tabs, which this would turn off.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
    }

    /// Windows closing as the app quits are still open as far as the next launch is concerned.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WindowTabs.isTerminating = true
        return .terminateNow
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A snapshot run stays out of the way: no Dock tile, and never the active app.
        guard SnapshotRun.directory == nil else {
            NSApp.setActivationPolicy(.accessory)
            return
        }
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
        self.selection = files.first?.id
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

/// The files to review, with a count of those hidden as vendored, lockfiles or generated.
struct FileList: View {
    let files: [FileDiff]
    let hiddenCount: Int
    @Binding var selection: FileDiff.ID?

    var body: some View {
        List(files, selection: $selection) { file in
            FileRow(file: file)
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

struct FileRow: View {
    let file: FileDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text((file.path as NSString).lastPathComponent).lineLimit(1)
            HStack(spacing: 6) {
                Text("+\(file.additions)").foregroundStyle(.diffSuccess)
                Text("-\(file.deletions)").foregroundStyle(.diffDanger)
                Text((file.path as NSString).deletingLastPathComponent)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            .font(.caption.monospacedDigit())
        }
        .help(file.path)
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
