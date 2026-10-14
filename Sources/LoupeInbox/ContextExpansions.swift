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
        expanded[ExpandedFile(range: range, path: file.path)] ?? file
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
        let key = ExpandedFile(range: range, path: file.path)
        expanded[key] = (expanded[key] ?? file).expanding(expansion, newFile: lines)
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
}

private struct FileVersion: Hashable {
    let path: String
    let oid: String
}

private struct ExpandedFile: Hashable {
    let range: DiffRange
    let path: String
}
