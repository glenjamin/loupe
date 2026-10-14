import AppKit
import LoupeInbox
import SwiftUI

/// The main window: a tab strip over the PR lists or the selected PR.
struct TabbedWindow: View {
    let tabs: TabsModel
    @AppStorage("showsClosedPullRequests") private var showsClosed = false

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(tabs: tabs)
            Group {
                if let tab = tabs.selectedTab {
                    PullRequestView(tab: tab, checkoutSearchRoots: tabs.lists.checkoutSearchRoots)
                        .id(tab.id)
                } else {
                    PullRequestListView(model: tabs.lists, showsClosed: showsClosed)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The window's chrome is declared once here, so switching tabs changes only what's in
        // it and never the title bar's height or title.
        .navigationTitle("Loupe")
        .navigationSubtitle(tabs.selectedTab?.title ?? "Pull Requests")
        .toolbar {
            ToolbarItemGroup {
                if let tab = tabs.selectedTab {
                    Button("Open on GitHub", systemImage: "safari") { NSWorkspace.shared.open(tab.pullRequest.url) }
                        .help("Open on GitHub")
                } else {
                    listsToolbarItems
                }
            }
        }
        // Here rather than on the lists, so refreshing carries on whichever tab is showing.
        .task { await tabs.lists.keepRefreshed() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await tabs.lists.refreshIfStale() }
        }
    }

    @ViewBuilder
    private var listsToolbarItems: some View {
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

/// Safari-style tabs: the selected one joins the content below it, the rest sit recessed on
/// the strip. The PR tabs scroll sideways when they don't fit.
struct TabStrip: View {
    let tabs: TabsModel

    var body: some View {
        HStack(spacing: 0) {
            TabButton(title: "Pull Requests", systemImage: "tray.full", isSelected: tabs.selection == .lists, showsSeparator: showsSeparator(after: 0), close: nil) {
                tabs.select(.lists)
            }
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(Array(tabs.tabs.enumerated()), id: \.element.id) { index, tab in
                            TabButton(title: tab.title, systemImage: "arrow.triangle.pull", isSelected: isSelected(index: index + 1), showsSeparator: showsSeparator(after: index + 1)) {
                                tabs.close(tab.id)
                            } select: {
                                tabs.select(.pullRequest(tab.id))
                            }
                            .help("\(tab.pullRequest.repository)#\(tab.pullRequest.number): \(tab.pullRequest.title)")
                            .id(tab.id)
                        }
                    }
                }
                .onChange(of: tabs.selection) { _, selection in
                    if case let .pullRequest(id) = selection {
                        withAnimation { scroller.scrollTo(id) }
                    }
                }
            }
        }
        .frame(height: 30)
        // Behind the tabs, so the selected tab's fill covers it and joins the content.
        .background(alignment: .bottom) { Divider() }
        .background(.bar)
    }

    /// Whether the tab at `index` in the strip, counting the lists' tab as 0, is selected.
    private func isSelected(index: Int) -> Bool {
        if index == 0 { return tabs.selection == .lists }
        guard tabs.tabs.indices.contains(index - 1) else { return false }
        return tabs.selection == .pullRequest(tabs.tabs[index - 1].id)
    }

    /// Separators are left out beside the selected tab, whose own shape sets it apart.
    private func showsSeparator(after index: Int) -> Bool {
        !isSelected(index: index) && !isSelected(index: index + 1)
    }
}

/// A tab in the strip. A closeable tab's icon turns into its close button while hovered.
struct TabButton: View {
    let title: String
    let systemImage: String
    let isSelected: Bool
    let showsSeparator: Bool
    let close: (() -> Void)?
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .frame(width: 14, height: 14)
                    .opacity(showsClose ? 0 : 1)
                Text(title)
                    .font(.callout.monospacedDigit())
                    .lineLimit(1)
            }
        }
        .buttonStyle(TabButtonStyle(isSelected: isSelected, isHovered: isHovered))
        // A sibling over the icon rather than inside the tab's label, so its click closes
        // the tab without also selecting it.
        .overlay(alignment: .leading) {
            if let close, showsClose {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 14, height: 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(.leading, TabButtonStyle.leadingPadding)
                .padding(.top, TabButtonStyle.topInset)
                .help("Close Tab")
            }
        }
        .overlay(alignment: .trailing) {
            if showsSeparator {
                Rectangle()
                    .fill(.separator)
                    .frame(width: 1, height: 16)
                    .padding(.top, TabButtonStyle.topInset)
            }
        }
        .onHover { isHovered = $0 }
    }

    private var showsClose: Bool { close != nil && isHovered }
}

struct TabButtonStyle: ButtonStyle {
    let isSelected: Bool
    let isHovered: Bool
    static let leadingPadding: CGFloat = 10
    /// Room above each tab so the selected one's rounded top shows against the strip.
    static let topInset: CGFloat = 4

    func makeBody(configuration: Configuration) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6)
        configuration.label
            .padding(.leading, Self.leadingPadding)
            .padding(.trailing, 14)
            .frame(minWidth: 100, maxHeight: .infinity)
            .foregroundStyle(isSelected ? .primary : .secondary)
            .background(fill(pressed: configuration.isPressed), in: shape)
            .contentShape(shape)
            .padding(.top, Self.topInset)
    }

    private func fill(pressed: Bool) -> AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.background) }
        if pressed { return AnyShapeStyle(.fill.tertiary) }
        if isHovered { return AnyShapeStyle(.fill.quaternary) }
        return AnyShapeStyle(.clear)
    }
}

/// Browser-style tab keys, in the File, View and Window menus.
struct TabCommands: Commands {
    /// Nil when a diff file was opened rather than the PR lists.
    let tabs: TabsModel?

    var body: some Commands {
        // Replaces the window's Close, so ⌘W closes the tab rather than the window.
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                if let tabs { tabs.closeSelected() } else { NSApp.keyWindow?.performClose(nil) }
            }
            .keyboardShortcut("w")
            Button("Close Window") { NSApp.keyWindow?.performClose(nil) }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        if let tabs {
            CommandGroup(after: .toolbar) {
                Button("Show Pull Requests") { tabs.select(.lists) }
                    .keyboardShortcut("t")
                ForEach(1..<9) { number in
                    Button("Show Tab \(number)") { tabs.selectTab(number: number) }
                        .keyboardShortcut(KeyEquivalent(Character("\(number)")))
                }
                Button("Show Last Tab") { tabs.selectTab(number: 9) }
                    .keyboardShortcut("9")
            }
            CommandGroup(before: .windowArrangement) {
                Button("Show Previous Tab") { tabs.selectPrevious() }
                    .keyboardShortcut("[", modifiers: [.command, .shift])
                Button("Show Next Tab") { tabs.selectNext() }
                    .keyboardShortcut("]", modifiers: [.command, .shift])
                Button("Previous Tab") { tabs.selectPrevious() }
                    .keyboardShortcut(.tab, modifiers: [.control, .shift])
                Button("Next Tab") { tabs.selectNext() }
                    .keyboardShortcut(.tab, modifiers: .control)
                Divider()
            }
        }
    }
}
