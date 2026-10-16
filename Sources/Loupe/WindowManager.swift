import AppKit
import LoupeInbox
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
    private let content = TabbedContentController()
    private var window: LoupeWindow?

    init(tabs: TabsModel) {
        self.tabs = tabs
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
        id.flatMap(tabs.tab(id:))?.title ?? "Pull Requests"
    }

    /// Shows the lists.
    func showLists() {
        select(nil)
    }

    /// Shows the PR's tab, or the lists for nil.
    func select(_ id: String?) {
        tabs.select(id)
        render()
    }

    /// Shows the strip's item `number`, counting from 1 with the lists first; 9 is always the
    /// last, as in browsers.
    func selectTab(number: Int) {
        let index = number == 9 ? tabs.tabs.count - 1 : number - 2
        if index < 0 {
            showLists()
        } else if tabs.tabs.indices.contains(index) {
            select(tabs.tabs[index].id)
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
        let selected = tabs.selected.flatMap(tabs.tab(id:))
        content.strip.update(
            tabs: tabs.tabs.map { TabStripItem(id: $0.id, title: $0.title, status: TabStatus($0.pullRequest), subtitle: $0.pullRequest.title) },
            selected: selected?.id
        )
        content.discard(keeping: Set(tabs.tabs.map(\.id)))
        content.show(selected?.id) {
            if let selected {
                hostingController(PullRequestView(tab: selected, checkoutSearchRoots: tabs.lists.checkoutSearchRoots))
            } else {
                hostingController(ListsContent(lists: tabs.lists))
            }
        }
        ReviewWindows.shared.show(selected, in: window)
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
        let chrome = WindowChrome(tabs: tabs, content: content)
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

    /// Keeps the lists refreshed, and watches open PRs for changes unless this is a snapshot run,
    /// which shouldn't wait on GitHub's notifications.
    private func startRefreshing() {
        Task { await tabs.lists.keepRefreshed() }
        if SnapshotRun.directory == nil { Task { await tabs.keepWatchingForChanges() } }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.tabs.lists.refreshIfStale() }
            }
        }
    }
}

/// The app's window. It is its own delegate, so having no close button it also refuses closing.
final class LoupeWindow: NSWindow, NSWindowDelegate {
    /// A snapshot run's window stays off-screen, where AppKit would otherwise pull it back.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        SnapshotRun.directory == nil ? super.constrainFrameRect(frameRect, to: screen) : frameRect
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
    let content: TabbedContentController
    @AppStorage("showsClosedPullRequests") private var showsClosed = false

    var body: some View {
        let tab = tabs.selected.flatMap(tabs.tab(id:))
        ControllerView(controller: content)
            .navigationTitle(tab?.title ?? "Pull Requests")
            .navigationSubtitle(tab?.pullRequest.title ?? "")
            .toolbar {
                ToolbarItemGroup {
                    if let tab {
                        let url = tab.pullRequest.url
                        Button("Open on GitHub", systemImage: "safari") { NSWorkspace.shared.open(url) }
                            .help("Open on GitHub")
                        Button("Copy Link", systemImage: "link") { copyLink(url) }
                            .keyboardShortcut("c", modifiers: [.command, .shift])
                            .help("Copy the PR's GitHub link")
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
        }
        if let lastRefreshed = lists.lastRefreshed {
            TimelineView(.everyMinute) { _ in
                Text("Refreshed \(lastRefreshed.formatted(.relative(presentation: .named)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        Toggle("Show closed and merged", systemImage: "archivebox", isOn: $showsClosed)
            .help("Show closed and merged")
        Button("Refresh", systemImage: "arrow.clockwise") { Task { await lists.refresh() } }
            .keyboardShortcut("r")
            .disabled(lists.isLoading)
    }
}

/// An AppKit view controller placed in SwiftUI.
private struct ControllerView: NSViewControllerRepresentable {
    let controller: NSViewController

    func makeNSViewController(context: Context) -> NSViewController { controller }
    func updateNSViewController(_ controller: NSViewController, context: Context) {}
}

/// The PR lists, whose refresh controls are in the window's toolbar.
private struct ListsContent: View {
    let lists: PullRequestListModel
    @AppStorage("showsClosedPullRequests") private var showsClosed = false

    var body: some View {
        PullRequestListView(model: lists, showsClosed: showsClosed)
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
                .keyboardShortcut("w")
            Button("Close All Tabs") { windows.closeAllTabs() }
                .keyboardShortcut("w", modifiers: [.command, .option])
        }
        CommandGroup(before: .windowArrangement) {
            Button("Show Pull Requests") { windows.showLists() }
                .keyboardShortcut("1")
            Button("Select Previous Tab") { windows.selectAdjacent(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Select Next Tab") { windows.selectAdjacent(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            ForEach(2..<9) { number in
                Button("Select Tab \(number)") { windows.selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
            Button("Select Last Tab") { windows.selectTab(number: 9) }
                .keyboardShortcut("9")
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
    let size = screen.visibleFrame.size
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
private func copyLink(_ url: URL) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(url.absoluteString, forType: .string)
    pasteboard.writeObjects([url as NSURL])
}
