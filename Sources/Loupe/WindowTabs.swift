import AppKit
import LoupeInbox
import SwiftUI

/// Groups the app's windows as native window tabs, keeps the stored open PRs in step with
/// their windows, and reopens them at launch.
@MainActor
final class WindowTabs {
    static let listsID = "lists"
    /// Windows sharing this join one tab group.
    static let tabbingIdentifier = "loupe"
    /// Set as the app quits, so windows closing then are still open for the next launch.
    static var isTerminating = false

    let tabs: TabsModel
    private var hasRestored = false
    private weak var listsWindow: NSWindow?
    private var pullRequestWindows: [String: NSWindow] = [:]
    /// PRs from the last run whose windows haven't appeared yet.
    private var pendingRestore: Set<String> = []
    private var restoreSelection: String?
    private var observers: [ObjectIdentifier: [NSObjectProtocol]] = [:]

    init(tabs: TabsModel) {
        self.tabs = tabs
    }

    /// The lists window has appeared. The first time, starts refreshing and reopens the PRs left
    /// open last run.
    func attachLists(_ window: NSWindow, openWindow: OpenWindowAction) {
        guard listsWindow !== window else { return }
        if let listsWindow {
            // The tab bar's "+" offers no way to hide it, and from the lists' tab it makes a second
            // lists window; the first is brought forward instead.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    window.close()
                    listsWindow.tabGroup?.selectedWindow = listsWindow
                    listsWindow.makeKeyAndOrderFront(nil)
                }
            }
            return
        }
        listsWindow = window
        configure(window, frameName: "Lists")
        observe(window, pullRequest: nil, frameName: "Lists")
        tabs.show = { openWindow(value: $0) }
        guard !hasRestored else { return }
        hasRestored = true
        startRefreshing()
        SnapshotRun.start(tabs: tabs)
        let ids = tabs.tabs.map(\.id)
        guard !ids.isEmpty else { return }
        pendingRestore = Set(ids)
        restoreSelection = tabs.selected
        // Once the lists window is on screen, so the PRs join its tab group after it.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                for id in ids { openWindow(value: id) }
            }
        }
    }

    func attach(_ window: NSWindow, pullRequest id: String, url: URL) {
        guard pullRequestWindows[id] !== window else { return }
        pullRequestWindows[id] = window
        configure(window, frameName: "Pull Request")
        observe(window, pullRequest: id, frameName: "Pull Request")
        guard pendingRestore.remove(id) != nil, pendingRestore.isEmpty else { return }
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.finishRestoring() }
        }
    }

    private func startRefreshing() {
        Task { await tabs.lists.keepRefreshed() }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.tabs.lists.refreshIfStale() }
            }
        }
    }

    /// Brings forward the window that was frontmost last run, after gathering any restored
    /// window that AppKit left out of the group.
    private func finishRestoring() {
        let windows = pullRequestWindows.values + [listsWindow].compactMap(\.self)
        if let group = windows.first?.tabGroup, windows.contains(where: { $0.tabGroup !== group }) {
            windows.first?.mergeAllWindows(nil)
        }
        guard let window = restoreSelection.flatMap({ pullRequestWindows[$0] }) ?? listsWindow else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func configure(_ window: NSWindow, frameName: String) {
        // Where the user last left it, or filling the screen the first time.
        if !window.setFrameUsingName(frameName), let screen = window.screen ?? NSScreen.main {
            window.setFrame(screen.visibleFrame, display: true)
        }
        window.tabbingMode = .preferred
        window.tabbingIdentifier = Self.tabbingIdentifier
        // The store reopens windows at launch; SwiftUI restoring them as well would duplicate them.
        window.isRestorable = false
        // AppKit tabs a window as it's first shown; one already showing joins the group here.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.joinGroup(window) }
        }
    }

    private func joinGroup(_ window: NSWindow) {
        guard window.tabbedWindows == nil else { return }
        let candidates = [NSApp.mainWindow].compactMap(\.self) + NSApp.windows
        guard let host = candidates.first(where: { $0 !== window && $0.isVisible && $0.tabbingIdentifier == Self.tabbingIdentifier }) else { return }
        (host.tabGroup?.windows.last ?? host).addTabbedWindow(window, ordered: .above)
        window.makeKeyAndOrderFront(nil)
    }

    /// Records which window is frontmost and where it's placed, and forgets a PR when its window
    /// closes. The frame is saved by hand as an autosave name can be held by only one window, and
    /// the PR windows share theirs.
    private func observe(_ window: NSWindow, pullRequest id: String?, frameName: String) {
        let center = NotificationCenter.default
        let key = ObjectIdentifier(window)
        let saveFrame: @Sendable (Notification) -> Void = { [weak window] _ in
            MainActor.assumeIsolated { window?.saveFrame(usingName: frameName) }
        }
        observers[key] = [
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main, using: saveFrame),
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main, using: saveFrame),
            center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.tabs.select(id) }
            },
            center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.closed(key, pullRequest: id) }
            },
        ]
    }

    private func closed(_ key: ObjectIdentifier, pullRequest id: String?) {
        observers.removeValue(forKey: key)?.forEach(NotificationCenter.default.removeObserver)
        if id == nil, let listsWindow, ObjectIdentifier(listsWindow) == key { self.listsWindow = nil }
        guard let id, !Self.isTerminating else { return }
        pullRequestWindows[id] = nil
        tabs.close(id)
    }
}

/// The PR lists, with their refresh controls in the toolbar.
struct ListsWindow: View {
    let windowTabs: WindowTabs
    @AppStorage("showsClosedPullRequests") private var showsClosed = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let lists = windowTabs.tabs.lists
        PullRequestListView(model: lists, showsClosed: showsClosed)
            .navigationTitle("Pull Requests")
            .toolbar {
                AppIconToolbarItem()
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
            .background(WindowAccessor { windowTabs.attachLists($0, openWindow: openWindow) })
    }
}

/// One open PR, titled `repo #number` (which its tab shows) with the PR's title beside it.
struct PullRequestWindow: View {
    let windowTabs: WindowTabs
    /// Fixed when the window opens, so it keeps showing while the window closes.
    @State private var tab: PullRequestTab?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    init(id: String?, windowTabs: WindowTabs) {
        self.windowTabs = windowTabs
        _tab = State(initialValue: id.flatMap(windowTabs.tabs.tab(id:)))
    }

    var body: some View {
        if let tab {
            let pullRequest = tab.pullRequest
            PullRequestView(tab: tab, checkoutSearchRoots: windowTabs.tabs.lists.checkoutSearchRoots)
                .navigationTitle(tab.title)
                .navigationSubtitle(pullRequest.title)
                .toolbar {
                    AppIconToolbarItem()
                    ToolbarItem {
                        Button("Open on GitHub", systemImage: "safari") { NSWorkspace.shared.open(pullRequest.url) }
                            .help("Open on GitHub")
                    }
                }
                .background(WindowAccessor { windowTabs.attach($0, pullRequest: tab.id, url: pullRequest.url) })
        } else {
            // A window for no open PR, such as from the tab bar's "+", shows the lists instead.
            Color.clear.onAppear {
                openWindow(id: WindowTabs.listsID)
                dismissWindow()
            }
        }
    }
}

/// The app icon at the toolbar's leading edge, so it shows whichever tab is in front.
struct AppIconToolbarItem: ToolbarContent {
    var body: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            if let titleBarIcon {
                Image(nsImage: titleBarIcon)
                    .resizable()
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// Tab keys beyond those AppKit's window tabs already give (⌘W, ⌃Tab, ⌃⇧Tab, and moving and
/// merging tabs), in the Window menu.
struct TabCommands: Commands {
    var body: some Commands {
        // PR windows open only from the lists.
        CommandGroup(replacing: .newItem) {}
        CommandGroup(before: .windowArrangement) {
            ShowListsButton()
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

/// Brings the lists forward, reopening them if closed.
private struct ShowListsButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show Pull Requests") { openWindow(id: WindowTabs.listsID) }
            .keyboardShortcut("t")
    }
}

/// Hands over the window its view is in, as soon as it's in one.
struct WindowAccessor: NSViewRepresentable {
    let attached: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowReader {
        WindowReader(attached: attached)
    }

    func updateNSView(_ view: WindowReader, context: Context) {}
}

final class WindowReader: NSView {
    private let attached: @MainActor (NSWindow) -> Void

    init(attached: @escaping @MainActor (NSWindow) -> Void) {
        self.attached = attached
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used from a nib") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { attached(window) }
    }
}

/// Selects the key window's tab `number`, as ⌘1–⌘9 do; 9 is always the last tab.
@MainActor
private func selectTab(number: Int) {
    guard let window = NSApp.keyWindow else { return }
    let windows = window.tabGroup?.windows ?? [window]
    let index = number == 9 ? windows.count - 1 : number - 1
    if windows.indices.contains(index) { windows[index].makeKeyAndOrderFront(nil) }
}

/// The app icon at toolbar size, separate from the Dock's copy so resizing it leaves that alone.
@MainActor
private let titleBarIcon: NSImage? = {
    let image = AppDelegate.iconURL.flatMap(NSImage.init(contentsOf:))
    image?.size = NSSize(width: 16, height: 16)
    return image
}()
