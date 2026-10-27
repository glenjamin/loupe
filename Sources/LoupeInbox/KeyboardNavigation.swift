import LoupeCore
import LoupeModel

extension PullRequestTab {
    /// The file `step` places from the shown one in the file list's order, the hidden files
    /// after the rest, stopping at either end; the first file when none is shown.
    public func selectAdjacentFile(_ step: Int) {
        guard case let .ready(changes)? = shownChanges else { return }
        let files = FileTree(paths: changes.files.map(\.path)).files + FileTree(paths: changes.hidden.map(\.path)).files
        guard let current = selectedFile, let index = files.firstIndex(of: current) else {
            selectedFile = files.first
            return
        }
        selectedFile = files[min(max(index + step, 0), files.count - 1)]
    }

    /// Shows the changes `step` places from those shown in the commit picker's order, the whole
    /// PR's then each commit, stopping at either end. The changes since an earlier head count
    /// as the whole PR's.
    public func showAdjacentCommit(_ step: Int) async {
        guard case let .ready(review) = phase else { return }
        let choices = [ChangesChoice.all] + review.commits.map { .commit($0.oid) }
        let index = choices.firstIndex(of: pendingChoice ?? shownChoice) ?? 0
        let next = choices[min(max(index + step, 0), choices.count - 1)]
        if next != pendingChoice ?? shownChoice { await show(next) }
    }

    /// The shown file's diff, if it's been diffed; a hidden file's once it's been asked for.
    public var selectedFileDiff: FileDiff? {
        guard case let .ready(changes)? = shownChanges, let path = selectedFile else { return nil }
        return changes.files.first { $0.id == path } ?? lastHiddenFileDiff(of: path)
    }
}
