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
            Divider()
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

struct TabStrip: View {
    let tabs: TabsModel

    var body: some View {
        HStack(spacing: 0) {
            TabButton(title: "Pull Requests", systemImage: "tray.full", isSelected: tabs.selection == .lists, close: nil) {
                tabs.select(.lists)
            }
            ScrollViewReader { scroller in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        ForEach(tabs.tabs) { tab in
                            TabButton(title: tab.title, systemImage: nil, isSelected: tabs.selection == .pullRequest(tab.id)) {
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
        .background(.bar)
    }
}

/// A tab in the strip. Closeable tabs show their close button while hovered.
struct TabButton: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let close: (() -> Void)?
    let select: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let close {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.borderless)
                .opacity(isHovered ? 1 : 0)
                .help("Close Tab")
            }
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
                .font(.callout.monospacedDigit())
                .lineLimit(1)
        }
        .padding(.leading, close == nil ? 12 : 6)
        .padding(.trailing, 12)
        .frame(minWidth: 90, maxHeight: .infinity)
        .background(isSelected ? AnyShapeStyle(.background) : AnyShapeStyle(.clear))
        .foregroundStyle(isSelected ? .primary : .secondary)
        .overlay(alignment: .trailing) { Divider() }
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { isHovered = $0 }
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
