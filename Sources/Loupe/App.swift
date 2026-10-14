import AppKit
import LoupeCore
import LoupeInbox
import LoupeStore
import SwiftUI

struct LoupeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var screen = Screen.initial

    var body: some Scene {
        WindowGroup(screen.title) {
            switch screen {
            case let .tabs(tabs):
                TabbedWindow(tabs: tabs)
                    .frame(minWidth: 900, minHeight: 500)
            case let .diff(model):
                ContentView(model: model)
                    .frame(minWidth: 900, minHeight: 600)
            }
        }
        .commands { TabCommands(tabs: screen.tabs) }
    }
}

@MainActor
enum Screen {
    case tabs(TabsModel)
    case diff(ReviewModel)

    static var initial: Screen {
        guard let path = LaunchOptions.diffPath else {
            let store = openStore()
            // The tabs take over opening PRs.
            let lists = PullRequestListModel(store: store) { _ in }
            return .tabs(TabsModel(lists: lists, store: store))
        }
        return .diff(ReviewModel.load(path: path))
    }

    var title: String {
        switch self {
        case .tabs: "Loupe"
        case let .diff(model): model.title
        }
    }

    var tabs: TabsModel? {
        if case let .tabs(tabs) = self { tabs } else { nil }
    }
}

/// Launched as a bare SwiftPM executable (no .app bundle), the process starts as a background
/// app and its window never takes keyboard focus unless it's promoted to a regular app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The app draws its own tab strip, so the system's window tabs and their menu items would
    /// only compete with it.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Without an .app bundle there's no Info.plist icon, so the Dock and About panel take it from here.
        if let url = Bundle.module.url(forResource: "Loupe", withExtension: "icns"), let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
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
                Text("+\(file.additions)").foregroundStyle(.green)
                Text("-\(file.deletions)").foregroundStyle(.red)
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

/// The on-disk store, or a throwaway one if it can't be opened, so the PR list still works.
private func openStore() -> PullRequestStore {
    let url = PullRequestStore.defaultURL
    do {
        return try PullRequestStore(url: url)
    } catch {
        FileHandle.standardError.write(Data("Couldn't open \(url.path(percentEncoded: false)), not keeping PRs between runs: \(error)\n".utf8))
        return try! PullRequestStore.inMemory()
    }
}
