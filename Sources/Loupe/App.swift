import AppKit
import LoupeCore
import SwiftUI

struct LoupeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var model = ReviewModel.load(path: LaunchOptions.diffPath)

    var body: some Scene {
        WindowGroup(model.title) {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
        }
    }
}

/// Launched as a bare SwiftPM executable (no .app bundle), the process starts as a background
/// app and its window never takes keyboard focus unless it's promoted to a regular app.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
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
            List(model.files, selection: $model.selection) { file in
                FileRow(file: file)
            }
            .safeAreaInset(edge: .bottom) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 300)
        } detail: {
            if let file = model.selectedFile {
                DiffView(file: file) { anchor in print("clicked \(anchor)") }
            } else {
                Text(model.error ?? "No file selected").foregroundStyle(.secondary)
            }
        }
    }

    private var summary: String {
        "\(model.files.count) files · \(model.excludedCount) vendored/lockfiles hidden"
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
