import Foundation
import LoupeGit
import LoupeModel
import LoupeStore
import Observation

/// The window's tabs: the PR lists, which are always first and can't be closed, then a tab per
/// opened PR. Open tabs and the selection are stored, so they come back next launch.
@Observable
@MainActor
public final class TabsModel {
    public let lists: PullRequestListModel
    public private(set) var tabs: [PullRequestTab] = []
    public private(set) var selection = TabSelection.lists

    private let store: PullRequestStore
    private let differ: PullRequestDiffer

    /// Restores the tabs stored by the previous run, and makes choosing a PR in `lists` open it
    /// here.
    public init(lists: PullRequestListModel, store: PullRequestStore, differ: PullRequestDiffer = PullRequestDiffer()) {
        self.lists = lists
        self.store = store
        self.differ = differ
        do {
            let saved = try store.openTabs()
            tabs = saved.pullRequests.map(makeTab)
            selection = saved.selected.map(TabSelection.pullRequest) ?? .lists
        } catch {
            FileHandle.standardError.write(Data("Couldn't restore open tabs: \(error)\n".utf8))
        }
        lists.onOpen = { [weak self] in self?.open($0) }
    }

    public var selectedTab: PullRequestTab? {
        guard case let .pullRequest(id) = selection else { return nil }
        return tabs.first { $0.id == id }
    }

    /// Selects the PR's tab, opening one at the end if it has none.
    public func open(_ pullRequest: PullRequestSummary) {
        if !tabs.contains(where: { $0.id == pullRequest.id }) {
            tabs.append(makeTab(pullRequest))
        }
        selection = .pullRequest(pullRequest.id)
        save()
    }

    public func select(_ selection: TabSelection) {
        guard order.contains(selection) else { return }
        self.selection = selection
        save()
    }

    /// Closes the PR's tab. If it was selected, the tab after it is selected, or failing that the
    /// one before.
    public func close(_ id: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: index)
        if selection == .pullRequest(id) {
            let neighbour = tabs.indices.contains(index) ? tabs[index] : tabs.last
            selection = neighbour.map { .pullRequest($0.id) } ?? .lists
        }
        save()
    }

    /// Closes the selected PR tab; the lists' tab stays.
    public func closeSelected() {
        if case let .pullRequest(id) = selection { close(id) }
    }

    /// Selects tab `number`, counting the lists as 1, as ⌘1–⌘9 do. 9 is always the last tab.
    public func selectTab(number: Int) {
        let order = order
        if number == 9 {
            select(order[order.count - 1])
        } else if order.indices.contains(number - 1) {
            select(order[number - 1])
        }
    }

    /// The next tab, wrapping from the last to the lists.
    public func selectNext() {
        step(by: 1)
    }

    /// The previous tab, wrapping from the lists to the last.
    public func selectPrevious() {
        step(by: -1)
    }

    /// The lists, then each PR tab.
    private var order: [TabSelection] {
        [.lists] + tabs.map { .pullRequest($0.id) }
    }

    private func step(by offset: Int) {
        let order = order
        let current = order.firstIndex(of: selection) ?? 0
        select(order[(current + offset + order.count) % order.count])
    }

    private func makeTab(_ pullRequest: PullRequestSummary) -> PullRequestTab {
        PullRequestTab(opened: pullRequest, lists: lists, store: store, differ: differ)
    }

    private func save() {
        let selected: String? = if case let .pullRequest(id) = selection { id } else { nil }
        do {
            try store.saveOpenTabs(tabs.map(\.id), selected: selected)
        } catch {
            FileHandle.standardError.write(Data("Couldn't save open tabs: \(error)\n".utf8))
        }
    }
}

public enum TabSelection: Hashable, Sendable {
    case lists
    /// The tab of the PR with this id.
    case pullRequest(String)
}
