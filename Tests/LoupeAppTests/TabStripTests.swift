import AppKit
@testable import Loupe
import LoupeInbox
import LoupeModel
import LoupeStore
import SwiftUI
import Testing

/// Drives the real tab strip with mouse events in an offscreen window.
@MainActor
struct TabStripTests {
    @Test func clickingATabSelectsItIncludingTheScrollingPullRequestTabs() async throws {
        let strip = try await Strip(opening: ["marmot", "atrium"])
        #expect(strip.tabs.selection == .pullRequest("atrium"))

        strip.click(atX: 20)
        #expect(strip.tabs.selection == .lists)
        strip.click(atX: strip.listsTabWidth + 20)
        #expect(strip.tabs.selection == .pullRequest("marmot"))
    }
}

@MainActor
private struct Strip {
    let tabs: TabsModel
    let window: NSWindow
    /// Where the PR tabs start.
    let listsTabWidth = NSHostingView(rootView: TabButton(title: "Pull Requests", systemImage: "tray.full", isSelected: true, showsSeparator: false, close: nil) {}).fittingSize.width

    init(opening repositories: [String]) async throws {
        let store = try PullRequestStore.inMemory()
        let pullRequests = repositories.enumerated().map { pullRequest($1, number: $0 + 1) }
        _ = try await store.replace(.toReview, with: pullRequests, refreshedAt: .now)
        let lists = PullRequestListModel(store: store, checkoutSearchRoots: [], onOpen: { _ in })
        tabs = TabsModel(lists: lists, store: store)
        for pullRequest in pullRequests { tabs.open(pullRequest) }

        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(x: -2000, y: -2000, width: 600, height: 30), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: TabStrip(tabs: tabs))
        // SwiftUI ignores events sent to a window that has never been shown.
        window.orderFrontRegardless()
        window.makeKey()
        settle()
    }

    /// Clicks the strip at `x`, midway down it.
    func click(atX x: CGFloat) {
        let point = NSPoint(x: x, y: 15)
        send(.leftMouseDown, at: point)
        send(.leftMouseUp, at: point)
    }

    private func send(_ type: NSEvent.EventType, at point: NSPoint) {
        guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else {
            Issue.record("Couldn't make a \(type) event")
            return
        }
        window.sendEvent(event)
        settle()
    }

    private func settle() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
    }
}

private func pullRequest(_ repository: String, number: Int) -> PullRequestSummary {
    PullRequestSummary(id: repository, repository: "tamarinworks/\(repository)", number: number, title: "A change", url: URL(string: "https://github.com/tamarinworks/\(repository)/pull/\(number)")!, author: nil, isDraft: false, reviewDecision: nil, checks: nil, updatedAt: .now, headRefName: "change", baseRefName: "main")
}
