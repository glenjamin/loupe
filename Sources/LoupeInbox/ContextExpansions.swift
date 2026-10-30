import Foundation
import LoupeCore
import LoupeGit
import Observation

/// The unchanged lines a reader has revealed around an open PR's hunks, as GitHub's expand
/// arrows reveal them, filled in from each file's text at the head of the changes shown. What's
/// revealed is kept per range and path, so going to another file and back keeps it; producing
/// the diff again starts afresh.
@Observable
@MainActor
public final class ContextExpansions {
    private let differ: PullRequestDiffer
    /// Each file's lines at a commit, once read. A commit never changes, so these never go stale.
    private var texts: [FileVersion: [String]] = [:]
    @ObservationIgnored private var reading: [FileVersion: Task<[String]?, Never>] = [:]
    /// Each file's diff with what's been revealed in it.
    private var expanded: [ExpandedFile: FileDiff] = [:]

    init(differ: PullRequestDiffer) {
        self.differ = differ
    }

    /// The file's diff with what's been revealed in it over `range`.
    func shown(_ file: FileDiff, in range: DiffRange) -> FileDiff {
        expanded[ExpandedFile(file, in: range)] ?? file
    }

    /// What can be revealed in the file, with its text read at `oid`; nil when nothing can.
    func expandable(_ file: FileDiff, at oid: String) -> ExpandableContext? {
        guard file.canExpandContext else { return nil }
        return ExpandableContext(newLineCount: texts[FileVersion(path: file.path, oid: oid)]?.count)
    }

    /// The file's lines at `oid`, read from the checkout once. A failed read is tried again
    /// next time.
    func lines(of path: String, at oid: String, in checkout: URL) async -> [String]? {
        let version = FileVersion(path: path, oid: oid)
        if let lines = texts[version] { return lines }
        if let underway = reading[version] { return await underway.value }
        let differ = differ
        let task = Task<[String]?, Never> {
            do {
                let text = try await differ.contents(of: path, at: oid, in: checkout)
                return await Task.detached { FileDiff.lines(of: text) }.value
            } catch {
                FileHandle.standardError.write(Data("Couldn't read \(path) at \(oid): \(error.localizedDescription)\n".utf8))
                return nil
            }
        }
        reading[version] = task
        let lines = await task.value
        reading[version] = nil
        if let lines { texts[version] = lines }
        return lines
    }

    /// Reveals more of the file over `range`, reading its text at the range's head first if
    /// need be. `file` is its diff as produced; the expansion counts hunks as shown.
    func expand(_ file: FileDiff, _ expansion: ContextExpansion, in range: DiffRange, checkout: URL) async {
        guard file.canExpandContext, let lines = await lines(of: file.path, at: range.head, in: checkout) else { return }
        let key = ExpandedFile(file, in: range)
        expanded[key] = (expanded[key] ?? file).expanding(expansion, newFile: lines)
    }

    /// Whether anything has been revealed in the file over `range`.
    func hasRevealed(_ file: FileDiff, in range: DiffRange) -> Bool {
        expanded[ExpandedFile(file, in: range)] != nil
    }

    /// Hides what's been revealed in the file over `range`, showing its diff as produced.
    func collapse(_ file: FileDiff, in range: DiffRange) {
        expanded[ExpandedFile(file, in: range)] = nil
    }

    /// Forgets what's been revealed, as the diff it was revealed in is produced again.
    func reset() {
        expanded = [:]
    }
}

extension PullRequestTab {
    /// The file as shown: its diff with whatever unchanged lines the reader has revealed.
    public func expandedFile(_ file: FileDiff) -> FileDiff {
        guard let range = shownRange else { return file }
        return contextExpansions.shown(file, in: range)
    }

    /// What can be revealed of the file's unchanged lines, or nil when nothing can: an added,
    /// deleted or binary file, or no checkout to read it from.
    public func expandableContext(of file: FileDiff) -> ExpandableContext? {
        guard checkout != nil, let range = shownRange else { return nil }
        return contextExpansions.expandable(file, at: range.head)
    }

    /// Reads the file at the head of the changes shown, so the lines after its last hunk can
    /// be offered too.
    public func readContext(of file: FileDiff) async {
        guard let checkout, let range = shownRange, file.canExpandContext else { return }
        _ = await contextExpansions.lines(of: file.path, at: range.head, in: checkout)
    }

    /// Reveals more of the file's unchanged lines; `file` is its diff as produced.
    public func expandContext(of file: FileDiff, _ expansion: ContextExpansion) async {
        guard let checkout, let range = shownRange else { return }
        await contextExpansions.expand(file, expansion, in: range, checkout: checkout)
    }

    /// Whether the reader has revealed any of the file's unchanged lines in the changes shown.
    public func hasRevealedContext(of file: FileDiff) -> Bool {
        guard let range = shownRange else { return false }
        return contextExpansions.hasRevealed(file, in: range)
    }

    /// Hides every line revealed in the file in the changes shown, back to its diff as produced.
    public func collapseContext(of file: FileDiff) {
        guard let range = shownRange else { return }
        contextExpansions.collapse(file, in: range)
    }

    /// Gives each line thread GitHub keeps no diff hunk for, as for a comment on lines outside
    /// the diff's hunks, its lines and a few above, read from the checkout at the commit it was
    /// made on, so the conversation shows its code as it does any other thread's.
    func fillMissingHunks() async {
        guard let checkout, let threads = conversation?.threads else { return }
        var built: [String: String] = [:]
        for thread in threads where thread.diffHunk.isEmpty && !thread.isOnFile && thread.side == .right {
            guard let oid = thread.originalCommitOid, let last = thread.originalLine,
                  let lines = await contextExpansions.lines(of: thread.path, at: oid, in: checkout)
            else { continue }
            built[thread.id] = unchangedHunk(of: lines, from: thread.originalStartLine ?? last, to: last)
        }
        guard !built.isEmpty, var updated = conversation else { return }
        for index in updated.threads.indices where updated.threads[index].diffHunk.isEmpty {
            if let hunk = built[updated.threads[index].id] { updated.threads[index].diffHunk = hunk }
        }
        if updated != conversation { conversation = updated }
    }
}

private struct FileVersion: Hashable {
    let path: String
    let oid: String
}

/// A file's diff over a range, kept apart with whitespace ignored, as its hunks differ.
private struct ExpandedFile: Hashable {
    let range: DiffRange
    let path: String
    let ignoresWhitespace: Bool

    init(_ file: FileDiff, in range: DiffRange) {
        self.range = range
        path = file.path
        ignoresWhitespace = file.ignoresWhitespace
    }
}

/// Lines `first` to `last` of a file as a hunk of unchanged lines, with up to three above them,
/// as GitHub's snippet of a thread shows; nil when the file doesn't have them. Its old side is
/// numbered as its new side, which a thread on the new side's snippet doesn't show.
private func unchangedHunk(of lines: [String], from first: Int, to last: Int) -> String? {
    guard first >= 1, first <= last, last <= lines.count else { return nil }
    let start = max(1, first - 3)
    let shown = lines[(start - 1)..<last]
    return "@@ -\(start),\(shown.count) +\(start),\(shown.count) @@\n" + shown.map { " " + $0 }.joined(separator: "\n")
}
