import AppKit
import LoupeInbox
import SwiftUI

/// Owns the lists window and one window per open PR, grouped as native window tabs, keeps the
/// stored open PRs in step with them, and reopens them at launch. The windows are AppKit's own
/// rather than SwiftUI scenes, so nothing offers the tab bar's "+" and nothing restores them
/// behind the store's back.
@MainActor
final class WindowManager {
    /// Windows sharing this join one tab group.
    static let tabbingIdentifier = "loupe"
    /// The lists window's saved frame, which a PR window opened outside a tab group takes too.
    private static let frameName = "Lists"

    let tabs: TabsModel
    private var listsWindow: LoupeWindow?
    private var pullRequestWindows: [String: LoupeWindow] = [:]
    /// Set as the app quits, which closes the windows, so the PRs in them stay stored for the next
    /// launch.
    private var isTerminating = false

    init(tabs: TabsModel) {
        self.tabs = tabs
        tabs.show = { [weak self] in self?.showPullRequest(id: $0) }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.isTerminating = true }
        }
    }

    /// The lists and the open PRs, in tab order.
    var windows: [NSWindow] {
        let all = [listsWindow].compactMap(\.self) + tabs.tabs.compactMap { pullRequestWindows[$0.id] }
        let grouped = all.first?.tabGroup?.windows ?? []
        return grouped + all.filter { window in !grouped.contains { $0 === window } }
    }

    /// Opens the lists and the PRs left open last run, brings forward the one that was frontmost,
    /// and starts keeping the lists refreshed.
    func restore() {
        let selected = tabs.selected
        showLists()
        for tab in tabs.tabs { show(tab) }
        if let window = selected.flatMap({ pullRequestWindows[$0] }) ?? listsWindow { select(window) }
        startRefreshing()
        SnapshotRun.start(tabs: tabs)
    }

    /// Brings the lists forward, reopening them if closed.
    func showLists() {
        if let listsWindow { return select(listsWindow) }
        let window = makeWindow(ListsContent(lists: tabs.lists), title: "Pull Requests")
        window.onClose = { [weak self] in self?.listsWindow = nil }
        listsWindow = window
        if let host = windows.first(where: { $0 !== window }) {
            host.addTabbedWindow(window, ordered: .below)
        } else {
            place(window)
        }
        // A snapshot run's off-screen frame isn't one to remember.
        if SnapshotRun.directory == nil { window.setFrameAutosaveName(Self.frameName) }
        select(window)
    }

    /// Brings the PR's window forward, opening it if it has none.
    func showPullRequest(id: String) {
        guard let tab = tabs.tab(id: id) else { return }
        show(tab)
    }

    private func show(_ tab: PullRequestTab) {
        if let window = pullRequestWindows[tab.id] { return select(window) }
        let content = PullRequestContent(tab: tab, checkoutSearchRoots: tabs.lists.checkoutSearchRoots)
        let window = makeWindow(content, title: tab.title)
        let id = tab.id
        window.onBecomeKey = { [weak self] in self?.tabs.select(id) }
        window.onClose = { [weak self] in
            guard let self, !self.isTerminating else { return }
            pullRequestWindows[id] = nil
            tabs.close(id)
        }
        if let last = windows.last {
            last.addTabbedWindow(window, ordered: .above)
        } else {
            place(window)
        }
        pullRequestWindows[id] = window
        select(window)
    }

    private func makeWindow(_ content: some View, title: String) -> LoupeWindow {
        let controller = NSHostingController(rootView: content.frame(minWidth: 900, minHeight: 500))
        // The window keeps its own size; the content only sets the minimum.
        controller.sizingOptions = [.minSize]
        controller.sceneBridgingOptions = [.title, .toolbars]
        let window = LoupeWindow(contentViewController: controller)
        window.title = title
        window.toolbarStyle = .unified
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        window.isReleasedWhenClosed = false
        window.onBecomeKey = { [weak self] in self?.tabs.select(nil) }
        addAppIcon(to: window)
        return window
    }

    /// Where the lists were last left, or filling the screen the first time. A snapshot run's
    /// windows are screen-sized but off every screen, so they never show behind the user's work;
    /// tabs added to the group take the same frame.
    private func place(_ window: NSWindow) {
        guard let screen = NSScreen.main else { return }
        if SnapshotRun.directory != nil {
            let size = screen.visibleFrame.size
            let offScreen = NSScreen.screens.reduce(NSRect.null) { $0.union($1.frame) }
            window.setFrame(NSRect(origin: NSPoint(x: offScreen.minX - size.width - 10_000, y: offScreen.minY - size.height - 10_000), size: size), display: false)
        } else if !window.setFrameUsingName(Self.frameName) {
            window.setFrame(screen.visibleFrame, display: false)
        }
    }

    private func select(_ window: NSWindow) {
        window.tabGroup?.selectedWindow = window
        bringForward(window)
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

/// A Loupe window, reporting when it comes to the front and when it closes.
final class LoupeWindow: NSWindow {
    var onBecomeKey: @MainActor () -> Void = {}
    var onClose: @MainActor () -> Void = {}

    override func becomeKey() {
        super.becomeKey()
        onBecomeKey()
    }

    /// A snapshot run's windows stay off-screen, where AppKit would otherwise pull them back.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        SnapshotRun.directory == nil ? super.constrainFrameRect(frameRect, to: screen) : frameRect
    }

    override func close() {
        onClose()
        super.close()
    }
}

/// The PR lists, with their refresh controls in the toolbar.
struct ListsContent: View {
    let lists: PullRequestListModel
    @AppStorage("showsClosedPullRequests") private var showsClosed = false

    var body: some View {
        PullRequestListView(model: lists, showsClosed: showsClosed)
            .navigationTitle("Pull Requests")
            .toolbar {
                ToolbarItemGroup {
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
    }
}

/// One open PR, titled `repo #number` (which its tab shows) with the PR's title beside it.
struct PullRequestContent: View {
    let tab: PullRequestTab
    let checkoutSearchRoots: [URL]

    var body: some View {
        let pullRequest = tab.pullRequest
        PullRequestView(tab: tab, checkoutSearchRoots: checkoutSearchRoots)
            .navigationTitle(tab.title)
            .navigationSubtitle(pullRequest.title)
            .toolbar {
                ToolbarItem {
                    Button("Open on GitHub", systemImage: "safari") { NSWorkspace.shared.open(pullRequest.url) }
                        .help("Open on GitHub")
                }
            }
    }
}

/// Tab keys beyond those AppKit's window tabs already give (⌘W, ⌃Tab, ⌃⇧Tab, and moving and
/// merging tabs), in the Window menu.
struct TabCommands: Commands {
    let windows: WindowManager

    var body: some Commands {
        // PR windows open only from the lists.
        CommandGroup(replacing: .newItem) {}
        CommandGroup(before: .windowArrangement) {
            Button("Show Pull Requests") { windows.showLists() }
                .keyboardShortcut("t")
            Button("Select Previous Tab") { NSApp.keyWindow?.selectPreviousTab(nil) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("Select Next Tab") { NSApp.keyWindow?.selectNextTab(nil) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            ForEach(1..<9) { number in
                Button("Select Tab \(number)") { selectTab(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
            Button("Select Last Tab") { selectTab(number: 9) }
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

/// Selects the key window's tab `number`, as ⌘1–⌘9 do; 9 is always the last tab.
@MainActor
private func selectTab(number: Int) {
    guard let window = NSApp.keyWindow else { return }
    let windows = window.tabGroup?.windows ?? [window]
    let index = number == 9 ? windows.count - 1 : number - 1
    if windows.indices.contains(index) { windows[index].makeKeyAndOrderFront(nil) }
}

/// The app icon at full size, scaled to fit where it's shown.
@MainActor
private let appIcon = AppDelegate.iconURL.flatMap(NSImage.init(contentsOf:))
