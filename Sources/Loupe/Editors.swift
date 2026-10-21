import AppKit
import LoupeGit

/// Opens `directory` in `editor`, bringing it to the front, through Launch Services rather than
/// the editor's command-line launcher, which an app started from Finder can't count on finding.
@MainActor
func open(_ directory: URL, in editor: Editor) async throws {
    guard !SnapshotRun.refuses("open \(directory.path(percentEncoded: false)) in \(editor.name)") else { return }
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: editor.bundleIdentifier) else {
        throw EditorNotInstalled(editor: editor)
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    _ = try await NSWorkspace.shared.open([directory], withApplicationAt: app, configuration: configuration)
}

struct EditorNotInstalled: Error, LocalizedError {
    let editor: Editor

    var errorDescription: String? {
        "\(editor.name) isn't installed."
    }
}
