import AppKit
import LoupeInbox
import LoupeModel
import SwiftUI

/// Owns the app's one window: a strip of tabs under the title bar, the lists as its first item
/// and one tab per open PR, which it keeps in step with `TabsModel` and restores at launch. The
/// window is AppKit's own rather than a SwiftUI scene, so nothing restores it behind the store's
/// back.
@MainActor
final class WindowManager {
    /// The window's saved frame.
    private static let frameName = "Lists"

    let tabs: TabsModel
    /// The lists' search, for as long as the window is open.
    let listSearch: ListSearch
    private let content = TabbedContentController()
    private var window: LoupeWindow?
    /// The lists' refresh and the open PRs' watches, while the screens are awake.
    private var refreshing: [Task<Void, Never>] = []

    init(tabs: TabsModel) {
        self.tabs = tabs
        listSearch = ListSearch(lists: tabs.lists)
        tabs.show = { [weak self] _ in
            guard let self else { return }
            render()
            if let window { bringForward(window) }
        }
        content.strip.onSelect = { [weak self] in self?.select($0) }
        content.strip.onClose = { [weak self] in self?.close($0) }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Local monitors run on the main thread, where the event came from.
            nonisolated(unsafe) let event = event
            let handled = MainActor.assumeIsolated { self?.handleControlTab(event) == true }
            return handled ? nil : event
        }
    }

    /// Asks for the folders to search for checkouts, starting at the first of the current ones.
    func askForCheckoutFolders() {
        let lists = tabs.lists
        chooseCheckoutFolders(startingAt: lists.checkoutSearchRoots.first) { try await lists.chooseCheckoutFolders($0) }
    }

    /// Opens the window on the item shown last run and starts keeping the lists refreshed.
    func restore() {
        let window = makeWindow()
        self.window = window
        render()
        observeTabs()
        bringForward(window)
        startRefreshing()
        SnapshotRun.start(windows: self)
    }

    /// The window, once restored.
    var mainWindow: NSWindow? { window }

    /// Makes Loupe the active app with its window in front, even if hidden or minimised, as for
    /// a link clicked in another app. A snapshot run stays in the background.
    func comeForward() {
        guard SnapshotRun.directory == nil, let window else { return }
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        if window.isMiniaturized { window.deminiaturize(nil) }
        bringForward(window)
    }

    /// What the window is titled with `id` shown, nil being the lists.
    func title(of id: String?) -> String {
        id.flatMap(tabs.item(id:))?.title ?? "Pull Requests"
    }

    /// Shows the lists.
    func showLists() {
        select(nil)
    }

    /// ⌘F: on the lists, their search; in a PR's tab, whatever has the focus finds in itself,
    /// as the diff and markdown boxes do with their find bars. ⌘G and ⇧⌘G step through its
    /// matches. The focus is the key window's, such as a comment's popover, or else this
    /// window's, which needn't be key.
    func find(_ step: NSTextFinder.Action = .showFindInterface) {
        guard tabs.selected != nil else {
            if step == .showFindInterface { listSearch.find() }
            return
        }
        let action = #selector(NSResponder.performTextFinderAction(_:))
        let sender = TextFinderSender(tag: step.rawValue)
        if !NSApp.sendAction(action, to: nil, from: sender) {
            _ = window?.firstResponder?.tryToPerform(action, with: sender)
        }
    }

    /// Shows the PR's tab, or the lists for nil.
    func select(_ id: String?) {
        tabs.select(id)
        render()
    }

    /// Shows the strip's item `number`, counting from 1 with the lists first; 9 is always the
    /// last, as in browsers.
    func selectTab(number: Int) {
        let index = number == 9 ? tabs.items.count - 1 : number - 2
        if index < 0 {
            showLists()
        } else if tabs.items.indices.contains(index) {
            select(tabs.items[index].id)
        }
    }

    /// Shows the item `offset` places along, the lists counting as the first.
    func selectAdjacent(_ offset: Int) {
        tabs.selectAdjacent(offset)
        render()
    }

    /// Closes the shown PR's tab; on the lists it quietly does nothing rather than beep.
    func closeSelectedTab() {
        if let id = tabs.selected { close(id) }
    }

    /// Closes every PR's tab, leaving the lists.
    func closeAllTabs() {
        tabs.closeAll()
        render()
    }

    /// Clicks the strip's item at `position` (0 for the lists) as a mouse would, so a snapshot
    /// run can show that the strip takes clicks. Returns whether there was such an item.
    func clickStripItem(at position: Int) -> Bool {
        guard let window, let point = content.strip.centreInWindow(ofItemAt: position) else { return false }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0) else { return false }
            window.sendEvent(event)
        }
        return true
    }

    private func close(_ id: String) {
        tabs.close(id)
        render()
    }

    /// Brings the strip, the shown content and the review keys' target up to date with the model.
    private func render() {
        let selected = tabs.selected.flatMap(tabs.item(id:))
        content.strip.update(tabs: tabs.items.map(stripItem), selected: selected?.id)
        content.discard(keeping: Set(tabs.items.map(\.id)))
        content.show(selected?.id) {
            switch selected {
            case let .pullRequest(tab):
                hostingController(PullRequestView(tab: tab))
            case let .pending(pending):
                hostingController(PendingTabView(pending: pending, retry: { [tabs] in tabs.retry(pending) }, close: { [weak self] in self?.close(pending.id) }))
            case nil:
                hostingController(ListsContent(lists: tabs.lists, search: listSearch))
            }
        }
        ReviewWindows.shared.show(selected?.pullRequestTab, in: window)
    }

    /// A PR's tab shows its state and title; a link's being looked up shows a spinner in their
    /// place, and once it's failed says so.
    private func stripItem(_ item: TabItem) -> TabStripItem {
        switch item {
        case let .pullRequest(tab):
            TabStripItem(id: tab.id, title: tab.title, status: TabStatus(tab.pullRequest), subtitle: tab.pullRequest.title)
        case let .pending(pending):
            TabStripItem(id: pending.id, title: pending.title, status: nil, subtitle: pending.error == nil ? "" : "Couldn't open", isLookingUp: pending.error == nil)
        }
    }

    /// Renders again whenever the tabs, the selection or a tab's titles change.
    private func observeTabs() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeTabs() }
        }
    }

    private func makeWindow() -> LoupeWindow {
        let chrome = WindowChrome(tabs: tabs, search: listSearch, content: content)
        let controller = NSHostingController(rootView: chrome.frame(minWidth: 900, minHeight: 500))
        // The window keeps its own size; the content only sets the minimum.
        controller.sizingOptions = [.minSize]
        controller.sceneBridgingOptions = [.title, .toolbars]
        let window = LoupeWindow(contentViewController: controller)
        window.toolbarStyle = .unified
        // The strip's selected tab is the title bar's colour, so the two read as one.
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        // The lists are the app's home, so the window has no close button and refuses closing;
        // ⌘W closes PR tabs instead.
        window.styleMask.remove(.closable)
        window.delegate = window
        addAppIcon(to: window)
        if SnapshotRun.directory != nil {
            // Invisible and off every screen before it's ever ordered in; snapshots draw the views
            // directly, so neither shows in them.
            window.alphaValue = 0
            window.isExcludedFromWindowsMenu = true
            keepOffScreenForSnapshot(window)
        } else {
            if !window.setFrameUsingName(Self.frameName), let screen = NSScreen.main {
                window.setFrame(screen.visibleFrame, display: false)
            }
            window.setFrameAutosaveName(Self.frameName)
        }
        return window
    }

    /// ⌃Tab and ⌃⇧Tab step through the strip, as they did through native window tabs. A key
    /// monitor rather than menu shortcuts, as Tab never reaches a menu item.
    private func handleControlTab(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard let window, event.window === window, event.keyCode == tabKeyCode,
              modifiers == .control || modifiers == [.control, .shift]
        else { return false }
        selectAdjacent(modifiers.contains(.shift) ? -1 : 1)
        return true
    }

    /// Keeps the lists refreshed, and watches open PRs for changes and the checks on the merge
    /// commits of those merged unless this is a snapshot run, which shouldn't wait on GitHub. Coming back to the app or its window also
    /// checks the shown PR and reloads any new commits, which were only offered while it was read.
    private func startRefreshing() {
        keepRefreshing()
        // A refresh landing in a dark wake, the screens off and the lid perhaps closed, can
        // send the window's layout round for ever until AppKit stops the app; nobody's looking
        // then anyway, so nothing is fetched until the screens wake, when it all catches up.
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopRefreshing() }
        }
        workspace.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepRefreshing() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.tabs.lists.refreshIfStale() }
                self.tabs.checkShownForChanges()
            }
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tabs.checkShownForChanges() }
        }
    }

    /// Starts refreshing the lists and watching the open PRs, each starting with a round now,
    /// unless they're already going.
    private func keepRefreshing() {
        guard refreshing.isEmpty else { return }
        refreshing = [Task { await tabs.lists.keepRefreshed() }]
        if SnapshotRun.directory == nil {
            refreshing.append(Task { await tabs.keepWatchingForChanges() })
            refreshing.append(Task { await tabs.keepWatchingMergeCommits() })
        }
    }

    /// Stops them, along with any round under way.
    private func stopRefreshing() {
        for task in refreshing { task.cancel() }
        refreshing = []
    }
}

/// The app's window. It is its own delegate, so having no close button it also refuses closing.
final class LoupeWindow: NSWindow, NSWindowDelegate {
    /// A snapshot run's window stays off-screen, where AppKit would otherwise pull it back.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        SnapshotRun.directory == nil ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }

    /// A scripted snapshot run's window acts as key, as the user's would be, without activating
    /// the app, which would take the user's keyboard; views that act differently in the key
    /// window, such as a list taking clicks, then act as they would for the user.
    override var isKeyWindow: Bool {
        SnapshotScript.file != nil || super.isKeyWindow
    }

    /// A scripted snapshot run's pointer is where the script moved it, as the real mouse never
    /// visits the off-screen window; views that ask where it is, such as hover popovers, agree.
    override var mouseLocationOutsideOfEventStream: NSPoint {
        SnapshotScript.pointerLocation(in: self) ?? super.mouseLocationOutsideOfEventStream
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        styleMask.contains(.closable)
    }
}

/// Carries the shown item's title and toolbar into the window, around the AppKit strip and
/// content. Only a window's root hosting controller bridges these, so it lives here rather than
/// in each item's own hosting controller.
private struct WindowChrome: View {
    let tabs: TabsModel
    let search: ListSearch
    let content: TabbedContentController
    @AppStorage("showsClosedPullRequests") private var showsClosed = false
    @AppStorage(ListMode.key) private var mode = ListMode.lists

    var body: some View {
        let item = tabs.selected.flatMap(tabs.item(id:))
        ControllerView(controller: content)
            .navigationTitle(item?.title ?? "Pull Requests")
            .navigationSubtitle(item?.pullRequestTab?.pullRequest.title ?? "")
            .toolbar {
                ToolbarItemGroup {
                    if let item {
                        let url = item.url
                        Button("Open on GitHub", systemImage: "safari") { openInBrowser(url) }
                            .help("Open on GitHub (⇧⌘O)")
                        Button("Copy Link", systemImage: "link") { copyLink(url) }
                            .help("Copy the PR's GitHub link (⇧⌘C)")
                    } else {
                        listsItems
                    }
                }
            }
    }

    @ViewBuilder
    private var listsItems: some View {
        let lists = tabs.lists
        if lists.isLoading {
            ProgressView().controlSize(.small)
                .padding(.leading, 8)
        }
        if let lastRefreshed = lists.lastRefreshed {
            EveryMinute { now in
                Text("Refreshed \(lastRefreshed.ago(now: now))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
            }
        }
        Picker("View", selection: $mode) {
            Text("Lists").tag(ListMode.lists)
            Text("TODO").tag(ListMode.todo)
        }
        .pickerStyle(.segmented)
        .help("Show the two lists, or one list of what to do next")
        Toggle("Show closed and merged", systemImage: "archivebox", isOn: $showsClosed)
            .help("Show closed and merged")
            // The TODO view is of open PRs only.
            .disabled(mode == .todo)
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await lists.refresh() } }
            .help("Refresh (⌘R)")
            .disabled(lists.isLoading)
        ListSearchToolbarItem(search: search)
    }
}

/// An AppKit view controller placed in SwiftUI.
private struct ControllerView: NSViewControllerRepresentable {
    let controller: NSViewController

    func makeNSViewController(context: Context) -> NSViewController { controller }
    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}

/// The PR lists, whose refresh controls and search are in the window's toolbar.
private struct ListsContent: View {
    let lists: PullRequestListModel
    let search: ListSearch
    @AppStorage("showsClosedPullRequests") private var showsClosed = false
    @AppStorage(ListMode.key) private var mode = ListMode.lists

    var body: some View {
        PullRequestListView(model: lists, showsClosed: showsClosed, mode: mode)
            // Esc in the list, after Esc in the field cleared it and came back here.
            .onKeyPress(.escape) { search.escape() ? .handled : .ignored }
    }
}

/// Edit ▸ Find ▸ Find… (⌘F), which searches the lists while they're shown and otherwise asks
/// what has the focus in a PR's tab to find in itself, then Find Next (⌘G) and Find Previous
/// (⇧⌘G) in a PR's tab.
struct FindCommands: Commands {
    let windows: WindowManager

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()
            Menu("Find") {
                Button("Find…") { windows.find() }
                    .keyboardShortcut(.find)
                Button("Find Next") { windows.find(.nextMatch) }
                    .keyboardShortcut(.findNext)
                Button("Find Previous") { windows.find(.previousMatch) }
                    .keyboardShortcut(.findPrevious)
            }
        }
    }
}

/// The sender of a find action, which AppKit's text views read from its tag as they would a
/// menu item's.
private final class TextFinderSender: NSObject {
    @objc let tag: Int

    init(tag: Int) {
        self.tag = tag
    }
}

/// The tab keys: ⌘W and ⌥⌘W close PR tabs, ⌘⇧[ and ⌘⇧] step through the strip, and ⌘1–⌘9
/// pick an item in it by position, ⌘1 being the lists. ⌃Tab is the window manager's key monitor.
struct TabCommands: Commands {
    let windows: WindowManager

    var body: some Commands {
        // In place of SwiftUI's Close and Close All, which would close the window.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { windows.closeSelectedTab() }
                .keyboardShortcut(.closeTab)
            Button("Close All Tabs") { windows.closeAllTabs() }
                .keyboardShortcut(.closeAllTabs)
        }
        CommandGroup(before: .windowArrangement) {
            Button("Show Pull Requests") { windows.showLists() }
                .keyboardShortcut(.showLists)
            Button("Select Previous Tab") { windows.selectAdjacent(-1) }
                .keyboardShortcut(.previousTab)
            Button("Select Next Tab") { windows.selectAdjacent(1) }
                .keyboardShortcut(.nextTab)
            ForEach(2..<9) { number in
                Button("Select Tab \(number)") { windows.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
            Button("Select Last Tab") { windows.selectTab(number: 9) }
                .keyboardShortcut(.selectLastTab)
            Divider()
        }
    }
}

/// The app icon at the title bar's leading edge, as tall as the title bar and toolbar.
@MainActor
private func addAppIcon(to window: NSWindow) {
    guard let appIcon else { return }
    let height = window.frame.height - window.contentLayoutRect.maxY
    let padding: CGFloat = 4
    let imageView = NSImageView(image: appIcon)
    imageView.imageScaling = .scaleProportionallyUpOrDown
    imageView.frame = NSRect(x: padding, y: 0, width: height, height: height)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: height + padding, height: height))
    container.addSubview(imageView)
    let accessory = NSTitlebarAccessoryViewController()
    accessory.view = container
    accessory.layoutAttribute = .leading
    window.addTitlebarAccessoryViewController(accessory)
}

/// A shown item's content, which takes its title and toolbar from the window rather than giving
/// its own.
@MainActor
private func hostingController(_ view: some View) -> NSViewController {
    let controller = NSHostingController(rootView: view)
    controller.sceneBridgingOptions = []
    controller.sizingOptions = []
    return controller
}

/// In a snapshot run, puts the window screen-sized but off every screen, so it never shows behind
/// the user's work.
@MainActor
private func keepOffScreenForSnapshot(_ window: NSWindow) {
    guard SnapshotRun.directory != nil, let screen = NSScreen.main else { return }
    // Against the fixtures, the same size on any screen, so scripts see the same layout.
    let size = FixtureRun.directory == nil ? screen.visibleFrame.size : NSSize(width: 1440, height: 900)
    let screens = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
    let frame = NSRect(origin: NSPoint(x: screens.minX - size.width - 10_000, y: screens.minY - size.height - 10_000), size: size)
    if window.frame != frame { window.setFrame(frame, display: false) }
}

/// The virtual key code of Tab.
private let tabKeyCode: UInt16 = 48

/// The app icon at full size, scaled to fit where it's shown.
@MainActor
private let appIcon = AppDelegate.iconURL.flatMap(NSImage.init(contentsOf:))

/// Puts a link on the pasteboard as text and as a URL, so it pastes as either.
@MainActor
func copyLink(_ url: URL) {
    let pasteboard = SnapshotRun.pasteboard
    pasteboard.clearContents()
    pasteboard.setString(url.absoluteString, forType: .string)
    pasteboard.writeObjects([url as NSURL])
}

@MainActor
func copyText(_ text: String) {
    let pasteboard = SnapshotRun.pasteboard
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
}
