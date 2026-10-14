import Foundation
import LoupeGit
import LoupeModel
import LoupeStore
import Observation

/// The PRs open in their own windows, which the app groups as native window tabs, and which of
/// them was frontmost. Both are stored, so the windows come back next launch.
@Observable
@MainActor
public final class TabsModel {
    public let lists: PullRequestListModel
    /// In the order they were opened.
    public private(set) var tabs: [PullRequestTab] = []
    /// Nil when the PR lists were frontmost.
    public private(set) var selected: String?
    /// Brings the PR's window forward, opening it if it has none; set by the app.
    public var show: @MainActor (String) -> Void = { _ in }

    private let store: PullRequestStore
    private let differ: PullRequestDiffer

    /// Restores the PRs stored by the previous run, and makes choosing a PR in `lists` open it.
    public init(lists: PullRequestListModel, store: PullRequestStore, differ: PullRequestDiffer = PullRequestDiffer()) {
        self.lists = lists
        self.store = store
        self.differ = differ
        do {
            let saved = try store.openTabs()
            tabs = saved.pullRequests.map(makeTab)
            selected = saved.selected
        } catch {
            FileHandle.standardError.write(Data("Couldn't restore open tabs: \(error)\n".utf8))
        }
        lists.onOpen = { [weak self] in self?.open($0) }
    }

    public func tab(id: String) -> PullRequestTab? {
        tabs.first { $0.id == id }
    }

    /// Opens the PR, or focuses it if it's already open.
    public func open(_ pullRequest: PullRequestSummary) {
        if tab(id: pullRequest.id) == nil {
            tabs.append(makeTab(pullRequest))
        }
        selected = pullRequest.id
        save()
        show(pullRequest.id)
    }

    /// Records which PR is frontmost, or nil for the lists.
    public func select(_ id: String?) {
        guard id.map({ tab(id: $0) != nil }) ?? true, id != selected else { return }
        selected = id
        save()
    }

    /// Forgets the PR, as its window has closed.
    public func close(_ id: String) {
        tabs.removeAll { $0.id == id }
        if selected == id { selected = nil }
        save()
    }

    private func makeTab(_ pullRequest: PullRequestSummary) -> PullRequestTab {
        PullRequestTab(opened: pullRequest, lists: lists, store: store, differ: differ)
    }

    private func save() {
        do {
            try store.saveOpenTabs(tabs.map(\.id), selected: selected)
        } catch {
            FileHandle.standardError.write(Data("Couldn't save open tabs: \(error)\n".utf8))
        }
    }
}
