import AppKit
import LoupeCore
import LoupeInbox
import SwiftUI

/// A hidden npm lockfile's choice between its package changes and its diff, and those changes.
struct PackageLockPreview {
    /// Nil until asked for.
    let state: DiffState<PackageLockChanges>?
    let showsRawDiff: Bool
    let setShowsRawDiff: (Bool) -> Void
    /// How many review threads are on the file, which only its diff shows.
    let threadCount: Int

    /// Whether the package changes cover the diff: only when chosen and the lockfiles parsed.
    var showsChanges: Bool {
        if showsRawDiff { return false }
        if case .failed? = state { return false }
        return true
    }

    /// Why the package changes can't be shown, if they can't.
    var failure: String? {
        if case let .failed(message)? = state { return message }
        return nil
    }
}

/// The lockfile's package changes in key order, under a line counting them, as the
/// `diff-package-lock` tool lists them.
struct PackageLockChangesView: View {
    let preview: PackageLockPreview

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor)
            switch preview.state {
            case .diffing, .failed, nil:
                ProgressView("Comparing packages…")
            case let .ready(changes):
                list(changes)
            }
        }
    }

    private func list(_ changes: PackageLockChanges) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: changes.summary)
                    .font(.system(size: 12, weight: .semibold))
                if changes.changes.isEmpty {
                    Text("Only fields not listed here changed, such as where packages resolve from. The raw diff shows them.")
                        .foregroundStyle(.secondary)
                }
                if preview.threadCount > 0 {
                    Text(verbatim: "\(preview.threadCount) review \(preview.threadCount == 1 ? "thread is" : "threads are") on this file's lines, shown in the raw diff.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            if !changes.changes.isEmpty {
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(changes.changes.indices, id: \.self) { index in
                            PackageLockChangeRow(change: changes.changes[index])
                        }
                    }
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// `+ key version`, `− key version`, `• key from → to` or `• from → to version`, the glyph in
/// the diff's colour for what happened.
private struct PackageLockChangeRow: View {
    let change: PackageLockChange

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: glyph)
                .foregroundStyle(colour)
                .frame(width: 10)
            switch change {
            case let .added(key, version), let .removed(key, version):
                packageKey(key) + Text(verbatim: "  " + version).foregroundColor(.secondary)
            case let .updated(key, from, to):
                packageKey(key) + Text(verbatim: "  \(from) \u{2192} \(to)").foregroundColor(.secondary)
            case let .moved(from, to, version):
                packageKey(from) + Text(verbatim: " \u{2192} ").foregroundColor(.secondary) + packageKey(to)
                    + Text(verbatim: "  " + version).foregroundColor(.secondary)
            }
        }
        .font(.system(size: 12, design: .monospaced))
    }

    private var glyph: String {
        switch change {
        case .added: "+"
        case .removed: "\u{2212}"
        case .updated, .moved: "\u{2022}"
        }
    }

    private var colour: Color {
        switch change {
        case .added: .diffSuccess
        case .removed: .diffDanger
        case .updated, .moved: .diffAttention
        }
    }
}

extension PullRequestTab {
    /// The package changes and their toggle for a hidden npm lockfile; nil for any other file.
    func packageLockPreview(of file: FileDiff) -> PackageLockPreview? {
        guard PackageLockChanges.isPackageLock(file.path), case let .ready(changes)? = shownChanges,
              changes.hidden.contains(where: { $0.path == file.path })
        else { return nil }
        let threads = self.threads(on: file)
        return PackageLockPreview(
            state: packageLockChanges(of: file.path),
            showsRawDiff: showsRawDiff(of: file.path),
            setShowsRawDiff: { self.setShowsRawDiff($0, path: file.path) },
            threadCount: (threads?.anchored.reduce(0) { $0 + $1.threads.count } ?? 0) + (threads?.elsewhere.count ?? 0)
        )
    }
}

/// The key with where it's installed dimmed and the package's name in full, as a file's header
/// dims its directory.
private func packageKey(_ key: String) -> Text {
    guard let range = key.range(of: "node_modules/", options: .backwards) else { return Text(verbatim: key) }
    return Text(verbatim: String(key[..<range.upperBound])).foregroundColor(.secondary) + Text(verbatim: String(key[range.upperBound...]))
}
