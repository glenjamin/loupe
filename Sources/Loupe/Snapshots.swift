import AppKit
import LoupeCore
import LoupeFakeGitHub
import LoupeGit
import LoupeGitHub
import LoupeInbox
import LoupeModel
import SwiftUI
import os
import UniformTypeIdentifiers
import WebKit

/// Renders `window` as it looks on screen, title bar, toolbar and tab bar included. Drawn by the
/// app itself, so it needs no screen-recording permission. Web views draw in another process,
/// so each is asked for its own snapshot and drawn in over its place.
@MainActor
func snapshot(window: NSWindow) async -> NSImage {
    let image = NSImage(size: window.frame.size)
    for case let view? in [window.contentView?.superview, window.contentView] {
        guard let rep = render(view) else { continue }
        await drawWebViews(in: view, onto: rep)
        drawChildWindows(of: window, onto: rep)
        image.addRepresentation(rep)
        break
    }
    return image
}

/// The Debug menu, for seeing the app as an agent would.
struct DebugCommands: Commands {
    let windows: WindowManager

    var body: some Commands {
        CommandMenu("Debug") {
            Button("Save Snapshot of Window…") { saveSnapshotOfKeyWindow() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Snapshot All Tabs to Desktop") {
                Task { await snapshotAllTabsToDesktop(windows) }
            }
        }
    }
}

/// With `LOUPE_SNAPSHOT_DIR` set, the app writes a PNG of the window with each item of its tab
/// strip shown once the lists have refreshed and each PR's diff is ready or has failed (or a time
/// limit passes), then quits.
@MainActor
enum SnapshotRun {
    static let directory = ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_DIR"].map {
        URL(filePath: $0, directoryHint: .isDirectory)
    }
    /// A run whose markdown boxes open on Preview rather than Write.
    static let previewsDrafts = directory != nil && ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_PREVIEW"] == "1"
    /// What a run fills the comments it starts with: `LOUPE_SNAPSHOT_DRAFT=long` asks for a draft
    /// longer than any box grows to, `short` (or previewing alone) for the sample.
    fileprivate static let draft: String? = switch ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_DRAFT"] {
    case "long"?: longDraft
    case "short"?: sampleDraft
    default: previewsDrafts ? sampleDraft : nil
    }
    /// A run driving pulls with synthesised events, where a pull that fires only says so.
    static let isRehearsingPulls = directory != nil && ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_PULL_EVENTS"] != nil
    /// A run that holds the PRs' checks on GitHub unanswered, so the header's spinner is drawn.
    private static let isHoldingChecks = directory != nil && ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_HOLD_CHECK"] == "1"
    /// A run that holds each PR's conversation fetch unanswered, so its wait is drawn.
    private static let isHoldingConversations = directory != nil && ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_HOLD_CONVERSATION"] == "1"
    /// A link to open as if from another app, its lookup held unanswered unless asked not to.
    private static let openedLink = directory == nil ? nil : ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_OPEN_LINK"].flatMap(URL.init(string:))
    private static let isHoldingLinkLookups = openedLink != nil && ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_OPEN_LINK_ANSWERED"] != "1"
    private static let gitHubHold = GitHubHold(holdsConversations: isHoldingConversations, holdsNumberLookups: isHoldingLinkLookups)
    /// A run that merges each PR it can, with every write kept from GitHub.
    private static let isRehearsingMerges = directory != nil && ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_MERGING"] == "1"
    /// Every request a snapshot run makes of GitHub goes through this, which sends only reads,
    /// so nothing a run clicks can change anything there.
    /// That's the fixtures' GitHub in a run with `LOUPE_FIXTURES` set.
    static let readOnlyGitHub = if let fixtures = FixtureRun.gitHub { ReadOnlyTransport(wrapping: fixtures) } else { ReadOnlyTransport() }
    private static let gitHubToken: GitHubClient.TokenProvider = FixtureRun.gitHub == nil ? GitHubCLI.authToken : { @Sendable in FixtureGitHub.token }
    /// How the app talks to GitHub: directly, except in a snapshot run, which only reads, and
    /// may hold some of it or rehearse merges.
    static let gitHubClient = if directory == nil {
        GitHubClient()
    } else if isRehearsingMerges {
        GitHubClient(token: gitHubToken, transport: MergeRehearsal())
    } else if isHoldingChecks || isHoldingConversations || isHoldingLinkLookups {
        GitHubClient(token: gitHubToken, transport: gitHubHold)
    } else {
        GitHubClient(token: gitHubToken, transport: readOnlyGitHub)
    }
    static let gitHubNotifications = directory == nil ? GitHubNotifications() : GitHubNotifications(token: gitHubToken, transport: readOnlyGitHub)
    /// What a snapshot run kept from opening outside the app: links for the browser, and
    /// checkouts for an editor.
    private(set) static var blockedLaunches: [String] = []

    /// In a snapshot run, records `launch` instead of letting it open another app, which would
    /// show on the user's screen, and returns true.
    static func refuses(_ launch: String) -> Bool {
        guard directory != nil else { return false }
        blockedLaunches.append(launch)
        print("blocked in snapshot run: \(launch)")
        return true
    }

    static func start(windows: WindowManager) {
        guard let directory else { return }
        let environment = ProcessInfo.processInfo.environment
        // LOUPE_SNAPSHOT_APPEARANCE=<dark|light> draws the app in that appearance, whatever the
        // system's.
        switch environment["LOUPE_SNAPSHOT_APPEARANCE"] {
        case "dark"?: NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light"?: NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        let tabs = windows.tabs
        let deadline = Date.now.addingTimeInterval(20)
        let started = Date.now
        // LOUPE_SNAPSHOT_HOLD_PHASE=<resolving|fetching|diffing> holds each PR's first load at
        // that step, before any tab is shown and starts one, so the wait can be drawn.
        let hold = StepHold(step: environment["LOUPE_SNAPSHOT_HOLD_PHASE"].flatMap(DiffStep.init(named:)))
        for tab in tabs.tabs { tab.beforeStep = { await hold.wait(at: $0) } }
        Task {
            await FixtureRun.prepare()
            let lists = tabs.lists
            await wait(until: deadline) { !lists.isLoading && (lists.error != nil || (lists.lastRefreshed ?? .distantPast) >= started) }
            // LOUPE_SNAPSHOT_SCRIPT=<file> drives the run from a script instead of the hooks below.
            if let script = SnapshotScript.file { await SnapshotScript.run(script, windows: windows, directory: directory) }
            // LOUPE_SNAPSHOT_OPEN_LINK=<url> opens the link as one from another app would, its
            // PR's lookup held so its tab waits; with LOUPE_SNAPSHOT_OPEN_LINK_ANSWERED=1 the
            // lookup goes through, so a link to a PR GitHub hasn't got shows why.
            if let openedLink, let links = AppDelegate.incomingLinks {
                let opening = Task { await links.open([openedLink]) }
                if isHoldingLinkLookups {
                    await wait(until: .now.addingTimeInterval(5)) { tabs.selected.flatMap(tabs.item(id:))?.pending != nil }
                } else {
                    await opening.value
                }
                print("\(openedLink.absoluteString): \(linkState(in: tabs))")
            }
            // A tab's content is made when it's first shown, so each is shown once, and its diff
            // asked for in case hidden content doesn't load it.
            let selected = tabs.selected
            for tab in tabs.tabs { windows.select(tab.id) }
            windows.select(selected)
            for tab in tabs.tabs { Task { await tab.load() } }
            await wait(until: deadline) { tabs.tabs.allSatisfy { $0.phase.isSettled(holding: hold.step) } }
            // LOUPE_SNAPSHOT_TAB picks each PR's section; a commit or file to show needs the files.
            if environment["LOUPE_SNAPSHOT_COMMIT"] != nil || environment["LOUPE_SNAPSHOT_FILE"] != nil || environment["LOUPE_SNAPSHOT_OPEN_COMMITS"] == "1" || environment["LOUPE_SNAPSHOT_HOLD_COMMIT"] != nil || environment["LOUPE_SNAPSHOT_SINCE"] != nil {
                for tab in tabs.tabs { tab.section = .files }
            } else if let section = environment["LOUPE_SNAPSHOT_TAB"].flatMap(ReviewSection.init(named:)) {
                for tab in tabs.tabs { tab.section = section }
            }
            // A conversation is shown once it's fetched and its web view has drawn it, or its
            // failure is; LOUPE_SNAPSHOT_HOLD_CONVERSATION=1 holds each fetch, so its wait is shown.
            let conversations = tabs.tabs.filter { $0.section == .conversation }
            if isHoldingConversations {
                await wait(until: deadline) { conversations.allSatisfy(\.isFetchingConversation) }
                for tab in conversations { print("\(tab.title): \(tab.isFetchingConversation ? "fetching the conversation, held" : "not fetching the conversation"), \(tab.conversation == nil ? "none stored" : "one stored")") }
            } else {
                await wait(until: deadline) {
                    conversations.allSatisfy { $0.isConversationSettled && ($0.conversation == nil || ConversationPage.existingPage(for: $0)?.isLoaded == true) }
                }
            }
            // LOUPE_SNAPSHOT_EDIT_DESCRIPTION=1 opens the description's editor on each of the
            // viewer's own PRs, fetching the description from GitHub as a click would.
            if environment["LOUPE_SNAPSHOT_EDIT_DESCRIPTION"] == "1" {
                for tab in tabs.tabs {
                    await tab.load()
                    guard tab.canEditDescription else { continue }
                    tab.section = .conversation
                    await tab.editDescription()
                }
            }
            // LOUPE_SNAPSHOT_COMMIT shows one commit's changes: its 1-based index, or an oid prefix.
            if let wanted = environment["LOUPE_SNAPSHOT_COMMIT"] {
                for tab in tabs.tabs {
                    guard case .ready(let review) = tab.phase, let commit = review.commits.picked(by: wanted) else { continue }
                    await tab.show(.commit(commit.oid))
                }
            }
            // LOUPE_SNAPSHOT_SINCE=review or =opened shows the changes since the viewer's last
            // review or last opening, once the conversation has brought the review's head.
            if let wanted = environment["LOUPE_SNAPSHOT_SINCE"] {
                for tab in tabs.tabs {
                    guard case .ready = tab.phase else { continue }
                    await wait(until: .now + 10) { tab.isConversationSettled }
                    await tab.prepareAnchors()
                    printAnchors(of: tab)
                    guard let anchor = tab.anchors.first(where: { $0.kind == (wanted == "opened" ? .lastOpened : .lastReview) }) else { continue }
                    await tab.show(.since(anchor))
                    printShownChanges(of: tab)
                }
            }
            // LOUPE_SNAPSHOT_FILE picks the first file whose path contains it, hidden ones after
            // the rest, to snapshot a given kind of file; a hidden npm lockfile's packages are
            // compared too.
            if let wanted = environment["LOUPE_SNAPSHOT_FILE"] {
                for tab in tabs.tabs {
                    guard case .ready(let changes)? = tab.shownChanges else { continue }
                    if let file = changes.files.first(where: { $0.path.contains(wanted) }) {
                        tab.selectedFile = file.id
                    } else if let file = changes.hidden.first(where: { $0.path.contains(wanted) }) {
                        tab.selectedFile = file.id
                        await tab.diffHiddenFile(file.path)
                        await tab.comparePackageLock(file.path)
                    }
                }
            }
            // LOUPE_SNAPSHOT_RENDERED=1 shows each shown markdown file rendered, once GitHub has
            // rendered it and its web view has loaded.
            if environment["LOUPE_SNAPSHOT_RENDERED"] == "1" {
                let rendered = tabs.tabs.filter { tab in
                    guard let file = tab.shownFile, let source = tab.markdownSource(of: file) else { return false }
                    tab.markdown.setRendered(true, path: file.path)
                    Task { await tab.renderMarkdown(source) }
                    return true
                }
                for tab in rendered { windows.select(tab.id) }
                windows.select(tabs.selected)
                await wait(until: .now.addingTimeInterval(20)) {
                    rendered.allSatisfy { tab in
                        guard let file = tab.shownFile, let source = tab.markdownSource(of: file) else { return true }
                        if case .failed = tab.markdown.rendering(of: source) { return true }
                        return MarkdownPage.existingPage(for: tab).map { $0.shown == source && $0.isLoaded } ?? false
                    }
                }
            }
            // LOUPE_SNAPSHOT_EXPAND=<n> clicks the up arrow on the nth hunk header (from 1) of each
            // shown diff, or the both-ways one where the gap is small; `all` reveals whole files.
            if let wanted = environment["LOUPE_SNAPSHOT_EXPAND"] {
                for tab in tabs.tabs {
                    guard let file = tab.shownFile else { continue }
                    await tab.readContext(of: file)
                    if wanted == "all" {
                        await revealWholeFile(file, in: tab)
                    } else if let hunk = Int(wanted) {
                        windows.select(tab.id)
                        if let window = windows.mainWindow { await clickExpandArrow(onHunk: hunk - 1, in: window) }
                    }
                }
                windows.select(tabs.selected)
                try? await Task.sleep(for: .milliseconds(1000))
                for tab in tabs.tabs {
                    guard let file = tab.shownFile else { continue }
                    print("\(file.path) now shows \(tab.expandedFile(file).hunks.map(\.header).joined(separator: " | "))")
                }
            }
            // Review threads come with the conversation, so a diff waits for it to show them.
            await wait(until: deadline) { tabs.tabs.allSatisfy(\.isConversationSettled) }
            // LOUPE_SNAPSHOT_OPEN_RESOLVED=1 opens every resolved thread, as clicking each would.
            if environment["LOUPE_SNAPSHOT_OPEN_RESOLVED"] == "1" {
                for tab in tabs.tabs {
                    tab.threadActivity.expanded.formUnion(tab.conversation?.threads.filter(\.isResolved).map(\.id) ?? [])
                }
            }
            // LOUPE_SNAPSHOT_REPLY=1 opens a reply on the first unresolved thread of each shown
            // file, as its Reply button would; nothing is typed or sent.
            if environment["LOUPE_SNAPSHOT_REPLY"] == "1" {
                for tab in tabs.tabs {
                    guard let file = tab.shownFile, let threads = tab.threads(on: tab.expandedFile(file)),
                          let thread = threads.anchored.flatMap(\.threads).first(where: { !$0.isResolved })
                    else { continue }
                    tab.startReply(to: thread)
                }
            }
            // LOUPE_SNAPSHOT_COMMENT=<line> hovers the row of that new line in each shown diff,
            // clicks the "+" that shows, as starting a comment would, then hovers it again, so
            // the snapshot has both. `<first>-<last>` first selects the rows of those new lines,
            // as a drag would, so the "+" starts a comment on them all. Nothing is typed or sent.
            if let lines = environment["LOUPE_SNAPSHOT_COMMENT"].flatMap(snapshotLines) {
                let line = lines.upperBound
                for tab in tabs.tabs {
                    windows.select(tab.id)
                    try? await Task.sleep(for: .milliseconds(800))
                    // A diff shown while its tab settles can take longer than that to appear.
                    await wait(until: .now + 10) { windows.mainWindow.flatMap(visibleDiff(in:))?.rendered?.rowAnchors.contains { $0 != nil } == true }
                    guard let window = windows.mainWindow else { continue }
                    if lines.count > 1 { selectRows(ofNewLines: lines, in: window) }
                    guard hoverRow(ofNewLine: line, in: window) else { continue }
                    visibleDiff(in: window)?.commentButton.performClick(nil)
                    try? await Task.sleep(for: .milliseconds(800))
                    _ = hoverRow(ofNewLine: line, in: window)
                    print("\(tab.title): \(tab.threadActivity.newComment.map(describe) ?? "no comment is open")")
                }
                windows.select(tabs.selected)
            }
            // LOUPE_SNAPSHOT_SUGGEST=1 presses ⌘G in each comment started on a line, as github.com's
            // "Add a suggestion" key, writing `suggest-<title>.png`, then ⌘⇧P, writing
            // `suggest-preview-<title>.png` once GitHub has rendered it (read-only). Nothing is sent.
            if environment["LOUPE_SNAPSHOT_SUGGEST"] == "1" {
                for tab in tabs.tabs {
                    guard let comment = tab.threadActivity.newComment else { continue }
                    windows.select(tab.id)
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let window = windows.mainWindow, let content = window.contentView,
                          let editor = descendants(of: content).compactMap({ $0 as? MarkdownEditingTextView }).first
                    else { continue }
                    window.makeFirstResponder(editor)
                    pressKeyEquivalent("g", modifiers: .command, keyCode: 5, in: window)
                    try? await Task.sleep(for: .milliseconds(500))
                    print("\(tab.title): suggesting on line \(comment.anchor.line) offers \(tab.suggestedLines(for: comment).map(String.init(describing:)) ?? "nothing"), draft \(String(reflecting: comment.draft.text)), cursor at \(editor.selectedRange().location)")
                    let written = directory.appending(path: "suggest-\(sanitised(windows.title(of: tab.id))).png")
                    try? await saveSnapshot(of: window, to: written)
                    print(written.path(percentEncoded: false))
                    pressKeyEquivalent("p", modifiers: [.command, .shift], keyCode: 35, in: window)
                    let draft = comment.draft.text
                    await wait(until: .now + 10) { tab.markdown.preview(ofDraft: draft).map { $0 != .rendering } ?? true }
                    print("\(tab.title): previewing the suggestion, \(String(describing: tab.markdown.preview(ofDraft: draft)).prefix(200))")
                    // The preview's page loads once drawn.
                    try? await Task.sleep(for: .milliseconds(1500))
                    let previewed = directory.appending(path: "suggest-preview-\(sanitised(windows.title(of: tab.id))).png")
                    try? await saveSnapshot(of: window, to: previewed)
                    print(previewed.path(percentEncoded: false))
                    pressKeyEquivalent("p", modifiers: [.command, .shift], keyCode: 35, in: window)
                }
                windows.select(tabs.selected)
            }
            // LOUPE_SNAPSHOT_DRAFT=<short|long> fills each comment started on a line with that
            // draft. LOUPE_SNAPSHOT_PREVIEW=1 opens every markdown box on Preview, and fills
            // each such comment with the short one unless asked for the long, for GitHub to
            // render (read-only), writing `preview-end-<title>.png` with the preview scrolled to
            // its end. Nothing is sent.
            if let draft {
                for tab in tabs.tabs {
                    guard let comment = tab.threadActivity.newComment else { continue }
                    windows.select(tab.id)
                    comment.draft.text = draft
                    guard previewsDrafts else {
                        print("\(tab.title): writing a comment of \(draft.count) characters on line \(comment.anchor.line)")
                        continue
                    }
                    await wait(until: .now + 10) { tab.markdown.preview(ofDraft: draft).map { $0 != .rendering } ?? true }
                    print("\(tab.title): previewing a comment on line \(comment.anchor.line), \(String(describing: tab.markdown.preview(ofDraft: draft)).prefix(80))")
                    // The preview's page loads once drawn.
                    try? await Task.sleep(for: .milliseconds(1500))
                    guard let window = windows.mainWindow, let content = window.contentView else { continue }
                    let previews = descendants(of: content).compactMap { $0 as? UnfocusedWebView }
                    for preview in previews {
                        _ = try? await preview.evaluateJavaScript("window.scrollTo(0, document.body.scrollHeight)", in: nil, contentWorld: .defaultClient)
                    }
                    try? await Task.sleep(for: .milliseconds(300))
                    let url = directory.appending(path: "preview-end-\(sanitised(windows.title(of: tab.id))).png")
                    try? await saveSnapshot(of: window, to: url)
                    print(url.path(percentEncoded: false))
                    for preview in previews {
                        _ = try? await preview.evaluateJavaScript("window.scrollTo(0, 0)", in: nil, contentWorld: .defaultClient)
                    }
                }
                windows.select(tabs.selected)
            }
            // LOUPE_SNAPSHOT_MIDDLE_CLICK=<line> middle-clicks the code of that new line's row in
            // each shown diff, which starts a comment there as its "+" would. Nothing is typed or sent.
            if let line = environment["LOUPE_SNAPSHOT_MIDDLE_CLICK"].flatMap(Int.init) {
                for tab in tabs.tabs {
                    windows.select(tab.id)
                    try? await Task.sleep(for: .milliseconds(800))
                    await wait(until: .now + 10) { windows.mainWindow.flatMap(visibleDiff(in:))?.rendered?.rowAnchors.contains { $0 != nil } == true }
                    guard let window = windows.mainWindow else { continue }
                    middleClickRow(ofNewLine: line, in: window)
                    try? await Task.sleep(for: .milliseconds(800))
                    print("middle-clicking new line \(line): \(tab.threadActivity.newComment.map { "a comment is open on \($0.anchor.side) line \($0.anchor.line)" } ?? "no comment is open")")
                }
                windows.select(tabs.selected)
            }
            // LOUPE_SNAPSHOT_DOUBLE_CLICK=<line> double-clicks the code of that new line's row in
            // each shown diff, which selects a word there as in any text view.
            if let line = environment["LOUPE_SNAPSHOT_DOUBLE_CLICK"].flatMap(Int.init) {
                for tab in tabs.tabs {
                    windows.select(tab.id)
                    try? await Task.sleep(for: .milliseconds(800))
                    await wait(until: .now + 10) { windows.mainWindow.flatMap(visibleDiff(in:))?.rendered?.rowAnchors.contains { $0 != nil } == true }
                    guard let window = windows.mainWindow else { continue }
                    doubleClickRow(ofNewLine: line, in: window)
                    try? await Task.sleep(for: .milliseconds(800))
                    let selected = visibleDiff(in: window)?.selectedRange().length ?? 0
                    print("double-clicking new line \(line): \(tab.threadActivity.newComment.map { "a comment is open on \($0.anchor.side) line \($0.anchor.line)" } ?? "no comment is open"), \(selected) characters selected")
                }
                windows.select(tabs.selected)
            }
            // LOUPE_SNAPSHOT_THREAD=<n> scrolls each shown diff to its nth block of threads (from
            // 1, in the order they come down the diff), once they've measured themselves.
            if let wanted = environment["LOUPE_SNAPSHOT_THREAD"].flatMap(Int.init) {
                for tab in tabs.tabs {
                    windows.select(tab.id)
                    try? await Task.sleep(for: .milliseconds(800))
                    if let window = windows.mainWindow { scrollToThreads(wanted - 1, in: window) }
                }
                windows.select(tabs.selected)
            }
            // LOUPE_SNAPSHOT_CLICK_FOOTER=1 clicks the footer's button at the end of each shown
            // diff, to see that a real click on it marks the file reviewed and moves on.
            if ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_CLICK_FOOTER"] == "1" {
                try? await Task.sleep(for: .milliseconds(500))
                printSelectedFiles(of: tabs, when: "before clicking")
                for tab in tabs.tabs {
                    windows.select(tab.id)
                    if let window = windows.mainWindow { await clickReviewFooter(in: window) }
                }
                windows.select(tabs.selected)
                try? await Task.sleep(for: .milliseconds(1500))
                printSelectedFiles(of: tabs, when: "after clicking")
            }
            // LOUPE_SNAPSHOT_HOLD_COMMIT=<n or oid prefix> picks that commit on each PR and holds
            // its diff, so the changes shown before stay, dimmed, beside the commit's name.
            if let wanted = environment["LOUPE_SNAPSHOT_HOLD_COMMIT"] {
                hold.step = .diffing
                for tab in tabs.tabs {
                    guard case .ready(let review) = tab.phase, let commit = review.commits.picked(by: wanted) else { continue }
                    Task { await tab.show(.commit(commit.oid)) }
                }
            }
            // LOUPE_SNAPSHOT_HOLD_RELOAD=1 reloads each PR's diff and holds it as it diffs, so the
            // diff shown before stays, dimmed, as it would while new commits are taken.
            if environment["LOUPE_SNAPSHOT_HOLD_RELOAD"] == "1" {
                hold.step = .diffing
                let reloading = tabs.tabs.filter { tab in
                    guard case .ready = tab.phase else { return false }
                    Task { await tab.reload() }
                    return true
                }
                await wait(until: .now.addingTimeInterval(20)) { reloading.allSatisfy { $0.reloading == .diffing } }
                for tab in reloading { print("\(tab.title): reloading, \(tab.reloading.map { "held at \($0)" } ?? "not held")") }
            }
            // LOUPE_SNAPSHOT_CLONING=1 clicks Clone on each PR with no checkout and holds the
            // clone before git runs, for good, so nothing is cloned and its wait is drawn.
            if environment["LOUPE_SNAPSHOT_CLONING"] == "1" {
                tabs.lists.beforeClone = { _ in await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in } }
                let cloning = tabs.tabs.filter { tab in
                    guard case .noCheckout = tab.phase else { return false }
                    Task { await tab.cloneCheckout() }
                    return true
                }
                await wait(until: .now.addingTimeInterval(5)) { cloning.allSatisfy { $0.checkoutClone != nil } }
                for tab in cloning { print("\(tab.title): \(tab.checkoutClone.map { "\($0), held" } ?? "not cloning")") }
            }
            // LOUPE_SNAPSHOT_HOLD_CHECK=1 checks each PR on GitHub, as showing it does, and holds
            // every request from then on unanswered, so each header shows its spinner.
            if isHoldingChecks {
                gitHubHold.start()
                for tab in tabs.tabs { Task { try? await tabs.lists.checkForChanges(to: [tab.id]) } }
                await wait(until: .now.addingTimeInterval(20)) { tabs.tabs.allSatisfy(\.isCheckingGitHub) }
                for tab in tabs.tabs { print("\(tab.title): \(tab.isCheckingGitHub ? "checking GitHub, held" : "not checking GitHub")") }
            }
            // LOUPE_SNAPSHOT_EDITOR=1 prints what each PR's "Open in" button would do, as a dry
            // run: nothing is fetched or switched and no editor is opened.
            if environment["LOUPE_SNAPSHOT_EDITOR"] == "1" {
                for tab in tabs.tabs {
                    await tab.load()
                    print(await editorPlan(for: tab))
                }
            }
            // LOUPE_SNAPSHOT_LATER=<seconds> snapshots each shown conversation as
            // `later-before-<title>.png`, moves its page's clock on that far, which rewords its
            // times in place as the minute tick would once that long had passed, and snapshots
            // it again as `later-after-<title>.png`.
            if let later = environment["LOUPE_SNAPSHOT_LATER"].flatMap(TimeInterval.init) {
                for tab in conversations {
                    guard let page = ConversationPage.existingPage(for: tab) else { continue }
                    windows.select(tab.id)
                    try? await Task.sleep(for: .milliseconds(500))
                    guard let window = windows.mainWindow else { continue }
                    let name = sanitised(windows.title(of: tab.id))
                    let before = directory.appending(path: "later-before-\(name).png")
                    try? await saveSnapshot(of: window, to: before)
                    print(before.path(percentEncoded: false))
                    print("\(tab.title): \(await page.moveClock(by: later)) times reworded \(Int(later)) seconds on")
                    try? await Task.sleep(for: .milliseconds(300))
                    let after = directory.appending(path: "later-after-\(name).png")
                    try? await saveSnapshot(of: window, to: after)
                    print(after.path(percentEncoded: false))
                }
                windows.select(tabs.selected)
            }
            // A moment for the final state to be drawn.
            try? await Task.sleep(for: .milliseconds(500))
            do {
                // LOUPE_SNAPSHOT_CLICK_TAB clicks a strip item (1-based, or "lists") first and
                // snapshots the result, to show that the strip takes clicks.
                if let wanted = environment["LOUPE_SNAPSHOT_CLICK_TAB"] {
                    print(try await saveSnapshotAfterClicking(wanted, in: windows, to: directory).path(percentEncoded: false))
                }
                // LOUPE_SNAPSHOT_CLICK_CONVERSATION=1 shows each PR's files, clicks its sidebar's
                // Conversation row and snapshots the result, to show that the row takes clicks.
                if environment["LOUPE_SNAPSHOT_CLICK_CONVERSATION"] == "1" {
                    for url in try await saveSnapshotsAfterClickingConversation(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_CLICK_FOLDER=1 shows each PR's files, clicks the last directory
                // row drawn in its tree, then arrows down the list, printing the selected file each time.
                if environment["LOUPE_SNAPSHOT_CLICK_FOLDER"] == "1" {
                    for url in try await saveSnapshotsAfterClickingFolder(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_SHOW_STALE=1 clicks each column's caption to list the PRs
                // hidden as stale, and snapshots the result.
                if environment["LOUPE_SNAPSHOT_SHOW_STALE"] == "1" {
                    print(try await saveSnapshotAfterShowingStale(in: windows, to: directory).path(percentEncoded: false))
                }
                // LOUPE_SNAPSHOT_TODO=1 shows the lists in TODO mode, prints its sections and
                // snapshots it, then again with the first stack, Waiting and Over 6 months unfolded
                // by clicks, and at Over a month.
                if environment["LOUPE_SNAPSHOT_TODO"] == "1" {
                    for url in try await saveSnapshotsOfTodo(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_CLICK_STACK=1 prints the lists' stacks and each PR's stack bar,
                // then clicks the first other PR in each bar and snapshots what it showed.
                if environment["LOUPE_SNAPSHOT_CLICK_STACK"] == "1" {
                    for url in try await saveSnapshotsAfterClickingStacks(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_OPEN_COMMITS=1 opens each PR's list of commits to pick from, once
                // they're counted, and snapshots it.
                if environment["LOUPE_SNAPSHOT_OPEN_COMMITS"] == "1" {
                    for url in try await saveSnapshotsOfCommitLists(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_REVIEW=1 opens the review's summary on each PR the viewer can
                // review, and snapshots it.
                if environment["LOUPE_SNAPSHOT_REVIEW"] == "1" {
                    for url in try await saveSnapshotsOfReviews(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_PENDING_LIST=1 opens the list of pending comments on each PR with
                // a pending review, and snapshots it. Nothing is deleted.
                if environment["LOUPE_SNAPSHOT_PENDING_LIST"] == "1" {
                    for url in try await saveSnapshotsOfPendingLists(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_REVIEWERS=1 opens the Reviewers picker on each of the viewer's
                // own PRs once its candidates are fetched, and snapshots it.
                if environment["LOUPE_SNAPSHOT_REVIEWERS"] == "1" {
                    for url in try await saveSnapshotsOfReviewerPickers(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_MERGING=1 merges each of the viewer's PRs that can be, through a
                // transport that never lets a write reach GitHub, and snapshots it merging.
                if isRehearsingMerges {
                    for url in try await saveSnapshotsOfMerging(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_SHOW_CHECKS=1 opens the checks popover on the lists' first glyph
                // and each PR's header, and snapshots it.
                if environment["LOUPE_SNAPSHOT_SHOW_CHECKS"] == "1" {
                    for url in try await saveSnapshotsOfChecks(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_SHOW_VERDICT=1 prints the viewer's verdict on each PR, once its
                // conversation has arrived, and opens the header's popover about it, and snapshots it.
                if environment["LOUPE_SNAPSHOT_SHOW_VERDICT"] == "1" {
                    for url in try await saveSnapshotsOfVerdicts(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_VISUAL_REVIEW=1 prints each PR's visual review, opens its header
                // flag's popover, then clicks its sidebar row and snapshots the report once it has
                // loaded or failed.
                if environment["LOUPE_SNAPSHOT_VISUAL_REVIEW"] == "1" {
                    for url in try await saveSnapshotsOfVisualReviews(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_SHOW_THREAD=1 clicks each conversation's first "Show in diff", or
                // =reply its first "Reply…", and snapshots the conversation and what the click showed.
                if let wanted = environment["LOUPE_SNAPSHOT_SHOW_THREAD"] {
                    for url in try await saveSnapshotsOfShownThreads(replying: wanted == "reply", in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_FORCE_PUSH=1 clicks each conversation's first force-push "Show
                // changes" and snapshots the conversation and the changes it showed.
                if environment["LOUPE_SNAPSHOT_FORCE_PUSH"] == "1" {
                    for url in try await saveSnapshotsOfForcePushes(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_COMMENT_PR=1 clicks each conversation's "Add a comment…" and
                // snapshots the composer it opens. Nothing is typed or sent.
                if environment["LOUPE_SNAPSHOT_COMMENT_PR"] == "1" {
                    for url in try await saveSnapshotsOfConversationComments(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_EDIT_COMMENT=1 opens the editor on each PR's first comment the
                // viewer may edit, in its diff card and by the conversation's "Edit", fetching its
                // markdown (read-only), and snapshots both. Nothing is typed or saved.
                if environment["LOUPE_SNAPSHOT_EDIT_COMMENT"] == "1" {
                    for url in try await saveSnapshotsOfCommentEdits(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_QUOTE=1 selects text in a comment on the PR, a thread comment in
                // the conversation and one on the diff, presses r for each and snapshots the quote
                // in its composer. Nothing is sent.
                if environment["LOUPE_SNAPSHOT_QUOTE"] == "1" {
                    for url in try await saveSnapshotsOfQuotes(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_IMAGE=1 shows each shown image file, an SVG rendered, once read,
                // and snapshots a changed one in each way of comparing it.
                if environment["LOUPE_SNAPSHOT_IMAGE"] == "1" {
                    for url in try await saveSnapshotsOfImages(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_WHITESPACE=1 snapshots each PR's shown file with whitespace
                // changes shown, then hides them as the header's button does and snapshots it
                // again; the usual PNGs keep them hidden.
                if environment["LOUPE_SNAPSHOT_WHITESPACE"] == "1" {
                    for url in try await saveSnapshotsOfWhitespace(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_REACTIONS=1 scrolls each conversation to its first reaction and
                // opens the picker beside it, and snapshots it. Nothing is clicked or sent.
                if environment["LOUPE_SNAPSHOT_REACTIONS"] == "1" {
                    for url in try await saveSnapshotsOfReactions(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_PULL_EVENTS=<points> pulls each shown diff that far past its end
                // with synthesised trackpad scroll events, and snapshots it halfway and at the end;
                // LOUPE_SNAPSHOT_PULL_BACK=<points> then scrolls back that far before letting go.
                if let travel = environment["LOUPE_SNAPSHOT_PULL_EVENTS"].flatMap(Double.init) {
                    let back = environment["LOUPE_SNAPSHOT_PULL_BACK"].flatMap(Double.init) ?? 0
                    for url in try await saveSnapshotsOfPulls(CGFloat(travel), back: CGFloat(back), in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_DEEP_LINK=<url> <url>… opens each link as one from another app
                // would, waits for it to land and snapshots what it landed on while it's marked.
                if let wanted = environment["LOUPE_SNAPSHOT_DEEP_LINK"] {
                    let urls = wanted.split(separator: " ").compactMap { URL(string: String($0)) }
                    for url in try await saveSnapshotsOfDeepLinks(urls, in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                // LOUPE_SNAPSHOT_SEARCH=<query> presses ⌘F on the lists and types the query,
                // snapshots the matches, steps into them with ↓, clears and hides the search with
                // Esc, then searches again for the usual PNGs; and presses ⌘F in each PR's tab.
                if let query = environment["LOUPE_SNAPSHOT_SEARCH"] {
                    for url in try await saveSnapshotsOfSearch(query, in: windows, to: directory) { print(url.path(percentEncoded: false)) }
                }
                for url in try await saveSnapshotsOfAllTabs(in: windows, to: directory) { print(url.path(percentEncoded: false)) }
            } catch {
                FileHandle.standardError.write(Data("Couldn't write snapshots: \(error)\n".utf8))
            }
            NSApp.terminate(nil)
        }
    }

    fileprivate static func wait(until deadline: Date, for isDone: () -> Bool) async {
        while Date.now < deadline, !isDone() {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    private static func printSelectedFiles(of tabs: TabsModel, when: String) {
        for tab in tabs.tabs {
            print("\(when): selected \(tab.selectedFile.map { "\($0)" } ?? "none")")
        }
    }

    /// Scrolls the shown diff to its end, then clicks its footer's button through the window as
    /// the mouse would. The mouse-up is queued first, so a button's tracking loop finds it.
    private static func clickReviewFooter(in window: NSWindow) async {
        try? await Task.sleep(for: .milliseconds(300))
        guard let root = window.contentView,
              let footer = descendants(of: root).first(where: { $0 is NSHostingView<ReviewFooter> && !$0.isHiddenOrHasHiddenAncestor }),
              let document = footer.enclosingScrollView?.documentView
        else { return }
        document.scroll(NSPoint(x: 0, y: footer.frame.maxY))
        footer.scrollToVisible(footer.bounds)
        window.layoutIfNeeded()
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        let point = footer.convert(NSPoint(x: footer.bounds.midX, y: footer.bounds.midY), to: nil)
        let frameView = root.superview ?? root
        let hit = frameView.hitTest(frameView.convert(point, from: nil))
        let chain = sequence(first: hit, next: { $0?.superview }).prefix(while: { $0 != nil }).compactMap { $0 }.prefix(8)
        print("clicking the footer at \(point) in the window hits \(chain.map { String(describing: type(of: $0)) }.joined(separator: " < "))")
        let events = [NSEvent.EventType.leftMouseUp, .leftMouseDown].compactMap { type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard events.count == 2 else { return }
        NSApp.postEvent(events[0], atStart: false)
        window.sendEvent(events[1])
    }

    /// Scrolls the shown diff so a hunk's header is a little way down the view, then clicks the
    /// arrow there that reveals lines above the hunk, through the window as the mouse would.
    private static func clickExpandArrow(onHunk hunk: Int, in window: NSWindow) async {
        try? await Task.sleep(for: .milliseconds(300))
        guard let root = window.contentView,
              let textView = descendants(of: root).lazy.compactMap({ $0 as? DiffTextView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
              let rendered = textView.rendered, rendered.hunkRows.indices.contains(hunk),
              let layoutManager = textView.layoutManager, let container = textView.textContainer
        else { return }
        let row = rendered.hunkRows[hunk]
        let end = row + 1 < rendered.rowStarts.count ? rendered.rowStarts[row + 1] : rendered.text.length
        var arrow: NSRange?
        rendered.text.enumerateAttribute(.diffExpansion, in: NSRange(location: rendered.rowStarts[row], length: end - rendered.rowStarts[row])) { value, range, stop in
            guard let expansion = value as? ContextExpansion, expansion.hunk == hunk, expansion.direction == .above else { return }
            arrow = range
            stop.pointee = true
        }
        guard let arrow else {
            print("hunk \(hunk + 1) has nothing hidden above it to reveal")
            return
        }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(arrow)))
        let bounds = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: arrow, actualCharacterRange: nil), in: container)
        let origin = textView.textContainerOrigin
        textView.scroll(NSPoint(x: 0, y: max(0, bounds.minY + origin.y - 120)))
        window.layoutIfNeeded()
        window.displayIfNeeded()
        try? await Task.sleep(for: .milliseconds(300))
        let point = textView.convert(NSPoint(x: bounds.midX + origin.x, y: bounds.midY + origin.y), to: nil)
        let glyph = (rendered.text.string as NSString).substring(with: arrow).trimmingCharacters(in: .whitespaces)
        let frameView = root.superview ?? root
        let hit = frameView.hitTest(frameView.convert(point, from: nil))
        print("clicking \(glyph) on hunk \(hunk + 1)'s header at \(point) in the window hits \(hit.map { String(describing: type(of: $0)) } ?? "nothing")")
        guard let event = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return }
        window.sendEvent(event)
    }

    /// Scrolls the shown diff so its nth block of threads is a little way down the view,
    /// printing where each block's row is.
    private static func scrollToThreads(_ index: Int, in window: NSWindow) {
        guard let root = window.contentView,
              let textView = descendants(of: root).lazy.compactMap({ $0 as? DiffTextView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }),
              let rendered = textView.rendered, let layoutManager = textView.layoutManager
        else { return }
        let blocks = rendered.blockRows.sorted { $0.value < $1.value }
        print("thread blocks: \(blocks.map { "\($0.key) at row \($0.value)" }.joined(separator: ", "))")
        guard blocks.indices.contains(index), let range = rendered.range(ofBlock: blocks[index].key) else { return }
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
        textView.scroll(NSPoint(x: 0, y: max(0, fragment.minY + textView.textContainerOrigin.y - 100)))
    }

    /// Scrolls the shown diff so the row of a new line is a little way down, then moves the
    /// mouse over it as the pointer would, printing whether its "+" shows.
    /// Selects the rows of new lines in the shown diff, first to last, as a drag over them would.
    private static func selectRows(ofNewLines lines: ClosedRange<Int>, in window: NSWindow) {
        guard let textView = visibleDiff(in: window), let rendered = textView.rendered,
              let first = rendered.rowAnchors.firstIndex(where: { $0?.side == .right && $0?.line == lines.lowerBound }),
              let last = rendered.rowAnchors.firstIndex(where: { $0?.side == .right && $0?.line == lines.upperBound })
        else { return print("no rows for new lines \(lines) to select") }
        let end = rendered.rowStarts.indices.contains(last + 1) ? rendered.rowStarts[last + 1] - 1 : rendered.text.length
        textView.setSelectedRange(NSRange(location: rendered.rowStarts[first], length: end - rendered.rowStarts[first]))
        print("selected the rows of new lines \(lines.lowerBound)–\(lines.upperBound)")
    }

    private static func hoverRow(ofNewLine line: Int, in window: NSWindow) -> Bool {
        guard let (textView, point) = scrollToRow(ofNewLine: line, in: window) else {
            print("no row for new line \(line) to hover")
            return false
        }
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else { return false }
        textView.mouseMoved(with: event)
        print("hovering new line \(line): the comment button is \(textView.commentButton.isHidden ? "hidden" : "shown")")
        return !textView.commentButton.isHidden
    }

    /// Scrolls the shown diff so the row of a new line is a little way down, then middle-clicks
    /// its code through the window as the mouse would.
    private static func middleClickRow(ofNewLine line: Int, in window: NSWindow) {
        guard let (_, point) = scrollToRow(ofNewLine: line, in: window) else {
            return print("no row for new line \(line) to middle-click")
        }
        for type in [NSEvent.EventType.otherMouseDown, .otherMouseUp] {
            // AppKit's factory can't name the button, so the event is given the middle one through Quartz.
            guard let made = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .otherMouseDown ? 1 : 0)?.cgEvent else { return }
            made.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
            guard let event = NSEvent(cgEvent: made) else { return }
            window.sendEvent(event)
        }
    }

    /// Scrolls the shown diff so the row of a new line is a little way down, then double-clicks
    /// its code through the window as the mouse would. Each mouse-up is queued before its
    /// mouse-down, so a selection-tracking loop finds it.
    private static func doubleClickRow(ofNewLine line: Int, in window: NSWindow) {
        guard let (_, point) = scrollToRow(ofNewLine: line, in: window) else {
            return print("no row for new line \(line) to double-click")
        }
        for clickCount in 1...2 {
            let events = [NSEvent.EventType.leftMouseUp, .leftMouseDown].compactMap { type in
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0)
            }
            guard events.count == 2 else { return }
            NSApp.postEvent(events[0], atStart: false)
            window.sendEvent(events[1])
        }
    }

    /// Scrolls the shown diff so the row of a new line is a little way down the view, and gives
    /// a point in the window over that row's code.
    private static func scrollToRow(ofNewLine line: Int, in window: NSWindow) -> (DiffTextView, NSPoint)? {
        guard let textView = visibleDiff(in: window), let rendered = textView.rendered, let layoutManager = textView.layoutManager,
              let row = rendered.rowAnchors.firstIndex(where: { $0?.side == .right && $0?.line == line })
        else { return nil }
        let start = rendered.rowStarts[row]
        layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: start + 1))
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil)
        let top = fragment.minY + textView.textContainerOrigin.y
        textView.scroll(NSPoint(x: 0, y: max(0, top - 120)))
        window.layoutIfNeeded()
        return (textView, textView.convert(NSPoint(x: 300, y: top + fragment.height / 2), to: nil))
    }

    private static func visibleDiff(in window: NSWindow) -> DiffTextView? {
        guard let root = window.contentView else { return nil }
        return descendants(of: root).lazy.compactMap { $0 as? DiffTextView }.first { !$0.isHiddenOrHasHiddenAncestor }
    }

    /// Reveals every unchanged line of the file, closing each gap from the bottom up.
    private static func revealWholeFile(_ file: FileDiff, in tab: PullRequestTab) async {
        guard tab.expandableContext(of: file) != nil else { return }
        while tab.expandedFile(file).hunks.count > 1 {
            let before = tab.expandedFile(file).hunks.count
            await tab.expandContext(of: file, ContextExpansion(hunk: before - 1, direction: .above, lines: nil))
            if tab.expandedFile(file).hunks.count == before { return }
        }
        await tab.expandContext(of: file, ContextExpansion(hunk: 0, direction: .above, lines: nil))
        await tab.expandContext(of: file, ContextExpansion(hunk: 0, direction: .below, lines: nil))
    }
}

/// Writes the window to `directory` as `<index>-<title>.png` with each item of the tab strip shown
/// in turn, the lists first, and returns the files written.
@MainActor
func saveSnapshotsOfAllTabs(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for (index, id) in ([nil] + windows.tabs.items.map(\.id)).enumerated() {
        windows.select(id)
        let url = directory.appending(path: "\(index + 1)-\(sanitised(windows.title(of: id))).png")
        try await saveSnapshot(of: window, to: url)
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// Brings the window forward, without taking focus during a snapshot run, where the app must stay
/// behind whatever the user is doing.
@MainActor
func bringForward(_ window: NSWindow) {
    if SnapshotRun.directory != nil {
        window.orderBack(nil)
    } else {
        window.makeKeyAndOrderFront(nil)
    }
}

/// Keeps every window a snapshot run opens invisible, popovers included: AppKit moves a popover
/// onto a screen, away from the off-screen window it hangs from, where it would show over the
/// user's work. Snapshots draw windows' views directly, so they're drawn all the same.
@MainActor
func keepWindowsInvisible() {
    for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didUpdateNotification] {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { notification in
            // Windows post these on the main thread.
            let window = notification.object as? NSWindow
            MainActor.assumeIsolated {
                guard let window, window.alphaValue != 0 else { return }
                window.alphaValue = 0
            }
        }
    }
}

/// Clicks the strip item `wanted` names (1-based, or "lists") and writes the window as
/// `clicked-<title>.png`, titled by whatever the click showed.
@MainActor
private func saveSnapshotAfterClicking(_ wanted: String, in windows: WindowManager, to directory: URL) async throws -> URL {
    guard let window = windows.mainWindow, let position = wanted == "lists" ? 0 : Int(wanted),
          windows.clickStripItem(at: position)
    else { throw SnapshotError.noSuchTab(wanted) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appending(path: "clicked-\(sanitised(windows.title(of: windows.tabs.selected))).png")
    try await saveSnapshot(of: window, to: url)
    return url
}

/// Shows each PR's files, then clicks its Conversation row through the window as the mouse
/// would, printing the section before and after, and writes `conversation-<title>.png`.
@MainActor
private func saveSnapshotsAfterClickingConversation(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs {
        tab.section = .files
        windows.select(tab.id)
        try? await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        guard let root = window.contentView,
              let row = descendants(of: root).first(where: { $0 is ConversationRowMarker.Marker && !$0.isHiddenOrHasHiddenAncestor })
        else { continue }
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let before = tab.section
        // The mouse-up is queued first, so a tracking loop started by the mouse-down finds it.
        let events = [NSEvent.EventType.leftMouseUp, .leftMouseDown].compactMap { type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard events.count == 2 else { continue }
        NSApp.postEvent(events[0], atStart: false)
        window.sendEvent(events[1])
        try? await Task.sleep(for: .milliseconds(300))
        print("clicking Conversation at \(point) switched \(windows.title(of: tab.id)) from \(before) to \(tab.section)")
        let url = directory.appending(path: "conversation-\(sanitised(windows.title(of: tab.id))).png")
        try await saveSnapshot(of: window, to: url)
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// Shows each PR's files, clicks the last directory row drawn in its tree through the window as
/// the mouse would, then presses ↓ a few times in the list, printing the selected file and the list's
/// row count after each, and writes `folder-<title>.png`.
@MainActor
private func saveSnapshotsAfterClickingFolder(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs {
        tab.section = .files
        windows.select(tab.id)
        try? await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        guard let root = window.contentView,
              let row = descendants(of: root).last(where: { $0 is DirectoryRowMarker.Marker && !$0.isHiddenOrHasHiddenAncestor }),
              let table = sequence(first: row, next: \.superview).first(where: { $0 is NSTableView }) as? NSTableView
        else { continue }
        let title = windows.title(of: tab.id)
        func report(_ when: String) {
            print("\(title) \(when): selected \(tab.selectedFile ?? "none"), \(table.numberOfRows) rows, table row \(table.selectedRow)")
        }
        report("before clicking a folder")
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        // The mouse-up is queued first, so a tracking loop started by the mouse-down finds it.
        let events = [NSEvent.EventType.leftMouseUp, .leftMouseDown].compactMap { type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard events.count == 2 else { continue }
        NSApp.postEvent(events[0], atStart: false)
        window.sendEvent(events[1])
        try? await Task.sleep(for: .milliseconds(300))
        report("after clicking a folder")
        window.makeFirstResponder(table)
        let down = String(UnicodeScalar(UInt16(NSDownArrowFunctionKey)).map(Character.init) ?? " ")
        for press in 1...4 {
            if let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: down, charactersIgnoringModifiers: down, isARepeat: false, keyCode: 125) {
                window.sendEvent(key)
            }
            try? await Task.sleep(for: .milliseconds(300))
            report("after ↓ \(press)")
        }
        let url = directory.appending(path: "folder-\(sanitised(title)).png")
        try await saveSnapshot(of: window, to: url)
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// Shows the lists, clicks each column's caption counting its stale PRs through the window
/// as the mouse would, and writes `stale-shown.png`.
@MainActor
private func saveSnapshotAfterShowingStale(in windows: WindowManager, to directory: URL) async throws -> URL {
    guard let window = windows.mainWindow else { throw SnapshotError.noSuchTab("lists") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    windows.select(nil)
    try? await Task.sleep(for: .milliseconds(300))
    window.layoutIfNeeded()
    let captions = window.contentView.map { descendants(of: $0).filter { $0 is StaleToggleMarker.Marker && !$0.isHiddenOrHasHiddenAncestor } } ?? []
    if captions.isEmpty { print("no hidden PRs caption to click") }
    for caption in captions {
        window.layoutIfNeeded()
        let point = caption.convert(NSPoint(x: caption.bounds.midX, y: caption.bounds.midY), to: nil)
        // The mouse-up is queued first, so a tracking loop started by the mouse-down finds it.
        let events = [NSEvent.EventType.leftMouseUp, .leftMouseDown].compactMap { type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        if events.count == 2 {
            NSApp.postEvent(events[0], atStart: false)
            window.sendEvent(events[1])
            print("clicked the hidden PRs caption at \(point)")
        }
        try? await Task.sleep(for: .milliseconds(300))
    }
    let url = directory.appending(path: "stale-shown.png")
    try await saveSnapshot(of: window, to: url)
    return url
}

/// Shows the lists, in TODO mode for a run started with `LOUPE_SNAPSHOT_TODO=1`, prints each of
/// its sections with every row's reason and writes `todo.png`, then presses ↓ twice and writes
/// `todo-selected.png`, then clicks the first "+N stacked"
/// through the window as the mouse would and writes `todo-stack.png`, then scrolls each of the
/// "Waiting on others", "Over a month" and "Over 6 months" headers to the top and writes
/// `todo-<name>.png`, clicking Waiting's and Over 6 months' first to unfold them.
@MainActor
private func saveSnapshotsOfTodo(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { throw SnapshotError.noSuchTab("lists") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    windows.select(nil)
    let todo = windows.tabs.lists.todo()
    let sections = [
        ("Review", todo.review), ("Yours", todo.yours), ("Waiting on others", todo.waiting), ("Over a month", todo.overAMonth), ("Over 6 months", todo.overSixMonths),
    ]
    for (title, items) in sections {
        print("\(title) (\(items.count))")
        for item in items {
            let stacked = item.stacked.isEmpty ? "" : " +\(item.stacked.count) stacked: \(item.stacked.map { "#\($0.pullRequest.number)" }.joined(separator: " "))"
            let quiet = Int(Date.now.timeIntervalSince(item.pullRequest.updatedAt) / 86400)
            let problems = item.problems.map { " + \($0.label)" }.joined()
            print("  \(item.pullRequest.repository) #\(item.pullRequest.number) — \(item.reason.label)\(problems), \(quiet)d quiet\(stacked)")
        }
    }
    try? await Task.sleep(for: .milliseconds(300))
    // The list should scroll from anywhere in the window, with only its rows narrowed.
    if let root = window.contentView,
       let scrollView = descendants(of: root).compactMap({ $0 as? NSScrollView }).first(where: { $0.documentView is NSTableView && !$0.isHiddenOrHasHiddenAncestor }),
       let table = scrollView.documentView as? NSTableView {
        let rows = (0..<table.numberOfRows).map { table.rect(ofRow: $0) }.filter { !$0.isEmpty }
        let content = rows.first.map { table.convert($0, to: nil) }
        print("window width \(window.frame.width), list scroll view \(scrollView.convert(scrollView.bounds, to: nil)), insets \(scrollView.contentInsets), first row \(content.map { "\($0)" } ?? "none")")
    }
    var urls = [directory.appending(path: "todo.png")]
    try await saveSnapshot(of: window, to: urls[0])
    // ↓ twice in the list, as a keyboard user would, to show the selection.
    if let root = window.contentView,
       let table = descendants(of: root).compactMap({ $0 as? NSTableView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }) {
        window.makeFirstResponder(table)
        for _ in 0..<2 {
            if let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}", isARepeat: false, keyCode: 125) {
                window.sendEvent(down)
            }
        }
        try? await Task.sleep(for: .milliseconds(300))
        print("selected row after ↓↓: \(table.selectedRow)")
        let url = directory.appending(path: "todo-selected.png")
        try await saveSnapshot(of: window, to: url)
        urls.append(url)
    }
    for (name, clicks) in [("stack", true), ("waiting", true), ("over-a-month", false), ("over-6-months", true)] {
        // A stack's row is shown where it is; a section's header goes to the top, its rows below.
        guard let marker = await scrollList(toMarker: name, in: window, toTop: name != "stack") else {
            print("no \(name) toggle found")
            continue
        }
        if !clicks {
            let url = directory.appending(path: "todo-\(name).png")
            try await saveSnapshot(of: window, to: url)
            urls.append(url)
            continue
        }
        let point = marker.convert(NSPoint(x: marker.bounds.midX, y: marker.bounds.midY), to: nil)
        // The mouse-up is queued first, so a tracking loop started by the mouse-down finds it.
        let events = [NSEvent.EventType.leftMouseUp, .leftMouseDown].compactMap { type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard events.count == 2 else { continue }
        NSApp.postEvent(events[0], atStart: false)
        window.sendEvent(events[1])
        print("clicked the \(name) toggle at \(point)")
        try? await Task.sleep(for: .milliseconds(300))
        if name != "stack" { _ = await scrollList(toMarker: name, in: window, toTop: true) }
        let url = directory.appending(path: "todo-\(name).png")
        try await saveSnapshot(of: window, to: url)
        urls.append(url)
    }
    return urls
}

/// Scrolls the window's list from its start a screen at a time until the control marked `name`
/// is in view, and on to bring it to the top if asked. The list draws only the rows in view and
/// measures them as they come in, so the control can't be found any other way.
@MainActor
private func scrollList(toMarker name: String, in window: NSWindow, toTop: Bool) async -> NSView? {
    guard let root = window.contentView,
          let scrollView = descendants(of: root).compactMap({ $0 as? NSScrollView }).first(where: { $0.documentView is NSTableView && !$0.isHiddenOrHasHiddenAncestor }),
          let document = scrollView.documentView else { return nil }
    let marker = { descendants(of: root).first { ($0 as? SnapshotClickMarker.Marker)?.name == name && !$0.isHiddenOrHasHiddenAncestor } }
    document.scroll(.zero)
    for _ in 0..<200 {
        try? await Task.sleep(for: .milliseconds(150))
        window.layoutIfNeeded()
        let visible = scrollView.contentView.bounds
        if let found = marker(), found.convert(found.bounds, to: document).intersects(visible) {
            guard toTop else { return found }
            document.scroll(NSPoint(x: 0, y: max(0, found.convert(found.bounds, to: document).minY - 8)))
            try? await Task.sleep(for: .milliseconds(300))
            window.layoutIfNeeded()
            return marker()
        }
        let end = document.bounds.height - visible.height
        guard visible.minY < end else { return nil }
        document.scroll(NSPoint(x: 0, y: min(end, visible.minY + visible.height * 0.8)))
    }
    return nil
}

/// Shows the lists, presses ⌘F through the menu bar and types `query` a key at a time, prints
/// the matching rows of the mode shown and writes `search.png`; presses ↓ and writes
/// `search-selected.png`; presses ⌘F and Esc, then Esc again, printing the search and the focus
/// after each, and writes `search-hidden.png`; then searches again, so the usual PNGs show it.
/// In each PR's tab it presses ⌘F with the conversation, then the diff, focused, printing whether
/// the diff's find bar showed, and writes `search-find-<title>.png`.
@MainActor
private func saveSnapshotsOfSearch(_ query: String, in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow, let root = window.contentView else { throw SnapshotError.noSuchTab("lists") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let lists = windows.tabs.lists
    let search = windows.listSearch
    func press(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode
        ) else { return }
        // As AppKit delivers a key: the window's views, then the menus, then the focus.
        if modifiers.contains(.command), window.performKeyEquivalent(with: event) || NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return }
        window.sendEvent(event)
    }
    func settle() async {
        try? await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
    }
    func focus() -> String {
        guard let responder = window.firstResponder else { return "nothing" }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSSearchField {
            return "the search field (\(type(of: field)))"
        }
        if let table = responder as? NSTableView { return "a list, row \(table.selectedRow) selected" }
        return "\(type(of: responder))"
    }
    func report(_ when: String) {
        print("\(when): field \(search.isShown ? "shown" : "hidden"), search \"\(lists.searchText)\", focus in \(focus())")
    }
    // The field takes the focus once the toolbar is drawn with it, and nothing draws this
    // off-screen window unasked, as the screen would a shown one.
    func fieldFocused() async {
        await SnapshotRun.wait(until: .now.addingTimeInterval(5)) {
            window.displayIfNeeded()
            return focus().hasPrefix("the search field")
        }
        await settle()
    }
    func typeText(_ text: String) async {
        for character in text {
            press(String(character), keyCode: character == " " ? 49 : 0)
        }
        await settle()
    }

    windows.select(nil)
    await settle()
    report("before")
    press("f", keyCode: 3, modifiers: .command)
    await fieldFocused()
    report("after ⌘F")
    await typeText(query)
    report("typed \"\(query)\"")
    if UserDefaults.standard.string(forKey: ListMode.key) == ListMode.todo.rawValue {
        let todo = lists.todo()
        for (title, items) in [("Review", todo.review), ("Yours", todo.yours), ("Waiting on others", todo.waiting), ("Over a month", todo.overAMonth), ("Over 6 months", todo.overSixMonths)] where !items.isEmpty {
            print("\(title) (\(items.count))")
            for item in items {
                let stacked = item.stacked.map { " +#\($0.pullRequest.number)" }.joined()
                print("  \(item.pullRequest.repository) #\(item.pullRequest.number) \(item.pullRequest.title) — \(item.reason.label)\(stacked)")
            }
        }
    } else {
        for list in PullRequestList.allCases {
            let listing = lists.listing(in: list)
            print("\(list) (\(listing.count))")
            for listed in listing {
                let on = listed.parent.map { " on #\($0.number)" } ?? ""
                print("  \(String(repeating: "  ", count: listed.depth))\(listed.pullRequest.repository) #\(listed.pullRequest.number) \(listed.pullRequest.title)\(on)")
            }
        }
    }
    var urls = [directory.appending(path: "search.png")]
    try await saveSnapshot(of: window, to: urls[0])
    press("\u{F701}", keyCode: 125, modifiers: [.numericPad, .function])
    await settle()
    report("after ↓")
    urls.append(directory.appending(path: "search-selected.png"))
    try await saveSnapshot(of: window, to: urls[urls.count - 1])
    press("f", keyCode: 3, modifiers: .command)
    await settle()
    report("after ⌘F again")
    press("\u{1B}", keyCode: 53)
    await settle()
    report("after Esc")
    press("\u{1B}", keyCode: 53)
    await settle()
    report("after a second Esc")
    urls.append(directory.appending(path: "search-hidden.png"))
    try await saveSnapshot(of: window, to: urls[urls.count - 1])

    for tab in windows.tabs.tabs {
        windows.select(tab.id)
        // The diff last, as the web view can keep the focus from the lists shown next.
        for section in [ReviewSection.conversation, .files] {
            tab.section = section
            try? await Task.sleep(for: .seconds(1))
            window.layoutIfNeeded()
            let shown = descendants(of: root).filter { !$0.isHiddenOrHasHiddenAncestor }
            guard let target = section == .files ? shown.first(where: { $0 is DiffTextView }) : shown.first(where: { $0 is WKWebView }) else {
                print("\(tab.title) \(section): nothing to focus")
                continue
            }
            window.makeFirstResponder(target)
            press("f", keyCode: 3, modifiers: .command)
            await settle()
            let findBar = target.enclosingScrollView?.isFindBarVisible == true ? "find bar shown" : "no find bar"
            print("\(tab.title) \(section): ⌘F with \(type(of: target)) focused: \(findBar), lists' field \(search.isShown ? "shown" : "hidden")")
            if section == .files {
                let url = directory.appending(path: "search-find-\(sanitised(tab.title)).png")
                try await saveSnapshot(of: window, to: url)
                urls.append(url)
            }
        }
    }

    windows.select(nil)
    await settle()
    press("f", keyCode: 3, modifiers: .command)
    await fieldFocused()
    await typeText(query)
    report("searching again for the usual PNGs")
    return urls
}

/// Prints each list's stacked PRs with their depth and what they're on, then for each PR tab with
/// a stack bar prints the bar and its merge hint, clicks the bar's first PR other than the tab's
/// own with a synthesised mouse down and up sent through the window, prints what the click
/// showed and writes `stack-<title>.png` of it. The PRs shown first are put back afterwards.
@MainActor
private func saveSnapshotsAfterClickingStacks(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    let tabs = windows.tabs
    for list in PullRequestList.allCases {
        for listed in tabs.lists.listing(in: list) where listed.depth > 0 || listed.parent != nil || tabs.lists.stacks.isStacked(listed.pullRequest) {
            let indent = String(repeating: "  ", count: listed.depth)
            let on = listed.parent.map { " on #\($0.number)" } ?? ""
            print("\(list.rawValue): \(indent)\(listed.pullRequest.repository) #\(listed.pullRequest.number)\(on)")
        }
    }
    let shown = tabs.selected
    let original = tabs.tabs.map(\.id)
    var urls: [URL] = []
    for id in original {
        guard let tab = tabs.tab(id: id), let line = tab.stackLine else { continue }
        let levels = line.levels.map { level in
            level.map { "#\($0.number)\($0.id == line.current ? " (this)" : "") \(StackReviewGlyph.words($0))" }.joined(separator: " · ")
        }
        print("\(tab.title): stack \(levels.joined(separator: " → ")); merge first: \(tab.mergeFirst.map { "#\($0.number)" } ?? "nothing")")
        windows.select(id)
        try? await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        guard let root = window.contentView,
              let entry = descendants(of: root).first(where: { $0 is StackEntryMarker.Marker && !$0.isHiddenOrHasHiddenAncestor }) else {
            print("\(tab.title): no stack entry to click")
            continue
        }
        let point = entry.convert(NSPoint(x: entry.bounds.midX, y: entry.bounds.midY), to: nil)
        // The mouse-up is queued first, so a tracking loop started by the mouse-down finds it.
        let events = [NSEvent.EventType.leftMouseUp, .leftMouseDown].compactMap { type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard events.count == 2 else { continue }
        NSApp.postEvent(events[0], atStart: false)
        window.sendEvent(events[1])
        await SnapshotRun.wait(until: .now.addingTimeInterval(10)) { tabs.selected != id && tabs.selected.flatMap(tabs.tab(id:)) != nil }
        try? await Task.sleep(for: .milliseconds(500))
        print("\(tab.title): clicked at \(point), now showing \(tabs.selected.flatMap(tabs.item(id:))?.title ?? "the lists")")
        let url = directory.appending(path: "stack-\(sanitised(windows.title(of: id))).png")
        try await saveSnapshot(of: window, to: url)
        urls.append(url)
    }
    for id in tabs.tabs.map(\.id) where !original.contains(id) { tabs.close(id) }
    windows.select(shown)
    return urls
}

/// Opens each diffed PR's list of commits to pick from, once they're counted and the changes since
/// each earlier head the viewer saw are looked at, and writes the window with it open as
/// `commits-<title>.png`. When the changes since one can't be shown, its row's popover saying why
/// is opened too, and written as `commits-help-<title>.png`.
@MainActor
private func saveSnapshotsOfCommitLists(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs {
        guard case .ready = tab.phase else { continue }
        await tab.countCommitChanges()
        // The viewer's latest review comes with the conversation.
        let deadline = ContinuousClock.now + .seconds(10)
        while !tab.isConversationSettled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await tab.prepareAnchors()
        printAnchors(of: tab)
        windows.select(tab.id)
        try? await Task.sleep(for: .milliseconds(300))
        tab.isPickingCommit = true
        try? await Task.sleep(for: .milliseconds(300))
        if let root = window.contentView,
           let picker = descendants(of: root).first(where: { $0 is CommitPickerMarker.Marker && !$0.isHiddenOrHasHiddenAncestor }) {
            placePopover(under: picker, in: window)
        }
        let name = sanitised(windows.title(of: tab.id))
        let url = directory.appending(path: "commits-\(name).png")
        try await saveSnapshot(of: window, to: url)
        written.append(url)
        if let list = window.childWindows?.first(where: \.isVisible), let content = list.contentView,
           let help = descendants(of: content).lazy.compactMap({ $0 as? HoverPopoverAnchor.AnchorView }).first {
            help.showPopover()
            try? await Task.sleep(for: .milliseconds(300))
            placeNestedPopover(under: help, in: list)
            let url = directory.appending(path: "commits-help-\(name).png")
            try await saveSnapshot(of: window, to: url)
            help.closePopover()
            written.append(url)
        }
        tab.isPickingCommit = false
    }
    windows.select(selected)
    return written
}

/// Moves a popover opened from `view`, inside the popover window `parent`, to just under it, as
/// AppKit moves it onto a screen, away from the off-screen window.
@MainActor
private func placeNestedPopover(under view: NSView, in parent: NSWindow) {
    guard let popover = parent.childWindows?.first(where: \.isVisible) else { return }
    let anchor = view.convert(view.bounds, to: nil)
    popover.setFrameTopLeftPoint(NSPoint(x: parent.frame.minX + anchor.minX, y: parent.frame.minY + anchor.minY))
}

/// Opens the review's summary on each PR the viewer can review, or their own with a review
/// pending, and writes the window with it
/// open as `review-<title>.png`.
@MainActor
private func saveSnapshotsOfReviews(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs where tab.canReview || (tab.canStartReview && tab.pendingReview != nil) {
        windows.select(tab.id)
        try? await Task.sleep(for: .milliseconds(300))
        tab.startWritingSummary()
        tab.reviewDraft.isWritingSummary = true
        try? await Task.sleep(for: .milliseconds(300))
        if let root = window.contentView,
           let button = descendants(of: root).first(where: { $0 is SummaryButtonMarker.Marker && !$0.isHiddenOrHasHiddenAncestor }) {
            placePopover(under: button, in: window)
        }
        let url = directory.appending(path: "review-\(sanitised(windows.title(of: tab.id))).png")
        try await saveSnapshot(of: window, to: url)
        tab.reviewDraft.isWritingSummary = false
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// Opens the list of pending comments on each PR with a pending review, printing what it
/// lists, and writes the window with it open as `pending-<title>.png`.
@MainActor
private func saveSnapshotsOfPendingLists(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs where tab.pendingReview != nil {
        windows.select(tab.id)
        try? await Task.sleep(for: .milliseconds(300))
        for pending in tab.pendingComments {
            let line = pending.thread.lines.map { "\($0.upperBound)" } ?? "-"
            print("pending: \(pending.thread.path):\(line) replying to \(pending.replyingTo?.author?.login ?? "nobody")")
        }
        tab.reviewDraft.isListingPending = true
        try? await Task.sleep(for: .milliseconds(300))
        if let root = window.contentView,
           let button = descendants(of: root).first(where: { $0 is PendingCommentsButtonMarker.Marker && !$0.isHiddenOrHasHiddenAncestor }) {
            placePopover(under: button, in: window)
        }
        let url = directory.appending(path: "pending-\(sanitised(windows.title(of: tab.id))).png")
        try await saveSnapshot(of: window, to: url)
        tab.reviewDraft.isListingPending = false
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// Opens the Reviewers button's picker on each PR that shows one, once the candidates are
/// fetched, printing those offered, and writes the window with it open as
/// `reviewers-<title>.png`. Nothing is requested.
@MainActor
private func saveSnapshotsOfReviewerPickers(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs where tab.reviewers != nil {
        windows.select(tab.id)
        do {
            try await tab.fetchReviewerCandidates()
        } catch {
            print("\(windows.title(of: tab.id)) couldn't fetch reviewers: \(error)")
        }
        let offered = tab.reviewerCandidates(matching: "") ?? []
        print("\(windows.title(of: tab.id)) ticks \(tab.requestedReviewers(matching: "").map(\.login))")
        print("\(windows.title(of: tab.id)) offers \(offered.map { tab.isSuggestedReviewer($0) ? "\($0.login) (suggested)" : $0.login })")
        try? await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        guard let root = window.contentView,
              let button = descendants(of: root).lazy.compactMap({ $0 as? ReviewersButtonMarker.Marker }).first(where: { !$0.isHiddenOrHasHiddenAncestor })
        else { continue }
        button.isPresented.wrappedValue = true
        try? await Task.sleep(for: .milliseconds(500))
        placePopover(under: button, in: window)
        let url = directory.appending(path: "reviewers-\(sanitised(windows.title(of: tab.id))).png")
        try await saveSnapshot(of: window, to: url)
        button.isPresented.wrappedValue = false
        try? await Task.sleep(for: .milliseconds(300))
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// On each PR tab whose merge slot shows something, prints what; where it can be merged, merges
/// it as the confirmed button does and writes `merging-<title>.png` while GitHub is at it. The
/// run's `MergeRehearsal` keeps every write from GitHub, so nothing is merged.
@MainActor
private func saveSnapshotsOfMerging(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs {
        let title = windows.title(of: tab.id)
        guard let readiness = tab.mergeReadiness else {
            print("\(title): nothing to merge")
            continue
        }
        let path = tab.pullRequest.stackId == nil ? "GraphQL, held" : "asynchronous merge, answered pending"
        print("\(title): merge \(readiness)\(readiness == .ready ? " via \(path)" : "")")
        guard readiness == .ready else { continue }
        windows.select(tab.id)
        Task { await tab.merge() }
        await SnapshotRun.wait(until: .now.addingTimeInterval(10)) { tab.isMerging }
        try? await Task.sleep(for: .milliseconds(500))
        print("\(title): \(tab.isMerging ? "merging" : "not merging: \(tab.mergeError ?? "no error")")")
        let url = directory.appending(path: "merging-\(sanitised(title)).png")
        try await saveSnapshot(of: window, to: url)
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// On each PR with review threads, scrolls its conversation to the first thread's "Show in diff",
/// or its "Reply…" when `replying`, and writes `thread-conversation-<title>.png`; then clicks it
/// in the page, so it goes through the web view's navigation as a real click does, prints where
/// that left the tab and where any reply opened, and writes `thread-<title>.png` with a reply's
/// popover moved back by its thread. Nothing is typed or sent.
@MainActor
private func saveSnapshotsOfShownThreads(replying: Bool, in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    // A reply is clicked where a reader can see it, in a thread that isn't folded away.
    let link = replying ? "details[open] > .thread-actions > a.thread-reply" : "a.thread-show"
    var written: [URL] = []
    for tab in windows.tabs.tabs where tab.conversation?.threads.isEmpty == false {
        tab.section = .conversation
        windows.select(tab.id)
        let page = ConversationPage.page(for: tab)
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline, !page.isLoaded { try? await Task.sleep(for: .milliseconds(100)) }
        let found = try? await page.webView.evaluateJavaScript(
            "(() => { const link = document.querySelector('\(link)'); if (!link) return false; link.closest('details').scrollIntoView(); window.scrollBy(0, -16); return true })()",
            in: nil, contentWorld: .defaultClient
        )
        guard found as? Bool == true else {
            print("\(tab.title): no \(link) to click")
            continue
        }
        try? await Task.sleep(for: .milliseconds(500))
        let title = sanitised(windows.title(of: tab.id))
        let conversation = directory.appending(path: "thread-conversation-\(title).png")
        try await saveSnapshot(of: window, to: conversation)
        _ = try? await page.webView.evaluateJavaScript("document.querySelector('\(link)').click()", in: nil, contentWorld: .defaultClient)
        try? await Task.sleep(for: .milliseconds(1200))
        let activity = tab.threadActivity
        let reply = page.replyPopover.map { "in a popover by \($0.threadId)" } ?? activity.replyingInConversation.map { "in a sheet for \($0)" } ?? "none"
        print("\(tab.title): clicked \(link); section \(tab.section), file \(tab.selectedFile ?? "none"), still to reveal \(activity.revealing ?? "nothing"), replies open \(activity.replies.count), reply over the conversation \(reply), unshown \(activity.unshown?.reason ?? "none")")
        if let popover = page.replyPopover?.popover {
            placePopover(under: page.webView.convert(popover.positioningRect, to: nil), in: window)
        }
        let shown = directory.appending(path: "thread-\(title).png")
        try await saveSnapshot(of: window, to: shown)
        page.closeReply()
        activity.closeConversationReply()
        written += [conversation, shown]
    }
    windows.select(selected)
    return written
}

/// Opens each link as one from another app would, through the app's incoming links, waits for
/// its PR's tab to land on what it points at (the conversation's page scrolled and marking it,
/// or the diff's thread revealed), prints where it landed and writes
/// `deep-link-<n>-<title>.png` while the mark shows.
@MainActor
private func saveSnapshotsOfDeepLinks(_ urls: [URL], in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow, let links = AppDelegate.incomingLinks else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let tabs = windows.tabs
    var written: [URL] = []
    for (index, url) in urls.enumerated() {
        await links.open([url])
        guard let tab = tabs.selected.flatMap(tabs.tab(id:)) else {
            print("\(url.absoluteString): \(linkState(in: tabs))")
            continue
        }
        let deadline = Date.now.addingTimeInterval(15)
        await SnapshotRun.wait(until: deadline) { tab.conversationLanding == nil && tab.threadActivity.revealing == nil }
        // Into the mark's moment, once the page or diff has scrolled.
        try? await Task.sleep(for: .milliseconds(600))
        var marked = "nothing marked in the page"
        if tab.section == .conversation, let page = ConversationPage.existingPage(for: tab) {
            let found = try? await page.webView.evaluateJavaScript(
                "(() => { const landed = [...document.querySelectorAll('.landed')].map(it => (it.dataset.commentId ?? it.dataset.threadId) + ' at ' + Math.round(it.getBoundingClientRect().top) + 'px'); return landed.length ? landed.join(', ') + ' of ' + window.innerHeight : null })()",
                in: nil, contentWorld: .defaultClient
            )
            if let found = found as? String { marked = "marked \(found)" }
        }
        let activity = tab.threadActivity
        print("\(url.absoluteString): \(tab.title), section \(tab.section), changes \(tab.shownChoice), file \(tab.selectedFile ?? "none"), thread highlighted \(activity.highlighted ?? "none"), \(marked)")
        let shown = directory.appending(path: "deep-link-\(index + 1)-\(sanitised(windows.title(of: tab.id))).png")
        try await saveSnapshot(of: window, to: shown)
        written.append(shown)
    }
    return written
}

/// On each PR's conversation with a force-push both of whose heads are known, scrolls to the
/// first one's "Show changes" and writes `force-push-conversation-<title>.png`, clicks it in the
/// page so it goes through the web view's navigation as a real click does, waits for the push's
/// changes, prints them and writes `force-push-<title>.png`, with the picker moved back under its
/// button if the click opened it to say why they can't be shown.
@MainActor
private func saveSnapshotsOfForcePushes(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    let link = "a.event-action"
    var written: [URL] = []
    for tab in windows.tabs.tabs where tab.conversation != nil {
        tab.section = .conversation
        windows.select(tab.id)
        let page = ConversationPage.page(for: tab)
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline, !page.isLoaded { try? await Task.sleep(for: .milliseconds(100)) }
        let found = try? await page.webView.evaluateJavaScript(
            "(() => { const link = document.querySelector('\(link)'); if (!link) return false; link.closest('.item').scrollIntoView({ block: 'center' }); return true })()",
            in: nil, contentWorld: .defaultClient
        )
        guard found as? Bool == true else {
            print("\(tab.title): no \(link) to click")
            continue
        }
        try? await Task.sleep(for: .milliseconds(500))
        let title = sanitised(windows.title(of: tab.id))
        let conversation = directory.appending(path: "force-push-conversation-\(title).png")
        try await saveSnapshot(of: window, to: conversation)
        _ = try? await page.webView.evaluateJavaScript("document.querySelector('\(link)').click()", in: nil, contentWorld: .defaultClient)
        // Fetching either head and replaying can take a while on a big repo.
        let settled = Date.now.addingTimeInterval(60)
        while Date.now < settled, !(tab.section == .files && tab.pendingChoice == nil && (tab.shownChoice != .all || tab.isPickingCommit)) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        printAnchors(of: tab)
        printShownChanges(of: tab)
        try? await Task.sleep(for: .milliseconds(500))
        if tab.isPickingCommit, let root = window.contentView,
           let picker = descendants(of: root).first(where: { $0 is CommitPickerMarker.Marker && !$0.isHiddenOrHasHiddenAncestor }) {
            placePopover(under: picker, in: window)
        }
        let shown = directory.appending(path: "force-push-\(title).png")
        try await saveSnapshot(of: window, to: shown)
        tab.isPickingCommit = false
        written += [conversation, shown]
    }
    windows.select(selected)
    return written
}

/// On each PR's conversation, scrolls to "Add a comment…" at its foot and clicks it in the page,
/// so it goes through the web view's navigation as a real click does, prints where the comment
/// opened, and writes `comment-<title>.png` with its popover moved back by the link. Nothing is
/// typed or sent.
@MainActor
private func saveSnapshotsOfConversationComments(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    let link = "a[data-new-comment]"
    var written: [URL] = []
    for tab in windows.tabs.tabs where tab.conversation != nil {
        tab.section = .conversation
        windows.select(tab.id)
        let page = ConversationPage.page(for: tab)
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline, !page.isLoaded { try? await Task.sleep(for: .milliseconds(100)) }
        let found = try? await page.webView.evaluateJavaScript(
            "(() => { const link = document.querySelector('\(link)'); if (!link) return false; link.scrollIntoView({ block: 'end' }); return true })()",
            in: nil, contentWorld: .defaultClient
        )
        guard found as? Bool == true else {
            print("\(tab.title): no \(link) to click")
            continue
        }
        try? await Task.sleep(for: .milliseconds(500))
        _ = try? await page.webView.evaluateJavaScript("document.querySelector('\(link)').click()", in: nil, contentWorld: .defaultClient)
        try? await Task.sleep(for: .milliseconds(1200))
        let comment = tab.conversationComment
        print("\(tab.title): clicked \(link); comment open \(comment.isOpen), draft \(comment.draft == nil ? "none" : "kept"), \(page.commentPopover == nil ? "no popover" : "in a popover by the link")")
        if let draft = SnapshotRun.draft, let commentDraft = comment.draft {
            commentDraft.text = draft
            if SnapshotRun.previewsDrafts {
                await SnapshotRun.wait(until: .now + 10) { tab.markdown.preview(ofDraft: draft).map { $0 != .rendering } ?? true }
            }
            // The popover grows to the draft, and a preview's page loads, once drawn.
            try? await Task.sleep(for: .milliseconds(1500))
            print("\(tab.title): comment filled with \(draft.count) characters, popover \(page.commentPopover.map { "\($0.contentSize)" } ?? "none")")
        }
        if let popover = page.commentPopover {
            placePopover(under: page.webView.convert(popover.positioningRect, to: nil), in: window)
        }
        let url = directory.appending(path: "comment-\(sanitised(windows.title(of: tab.id))).png")
        try await saveSnapshot(of: window, to: url)
        page.closeComment()
        tab.cancelConversationComment()
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// On each PR with a comment the viewer may edit, opens the editor in place on the first such
/// thread comment the diff shows, its markdown fetched from GitHub, and writes
/// `edit-diff-<title>.png`; then clicks the conversation's first "Edit" in the page, so it goes
/// through the web view's navigation as a real click does, prints where the edit opened and
/// writes `edit-<title>.png` with its popover moved back by the link. Nothing is typed or saved.
@MainActor
private func saveSnapshotsOfCommentEdits(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    let link = "a[data-edit-comment]"
    var written: [URL] = []
    for tab in windows.tabs.tabs {
        let title = sanitised(windows.title(of: tab.id))
        windows.select(tab.id)
        // What the viewer may edit is known only from a conversation fetched since GitHub was
        // asked for it, so wait for a fetch underway.
        let fetched = Date.now.addingTimeInterval(20)
        while Date.now < fetched, tab.conversation == nil || tab.isFetchingConversation { try? await Task.sleep(for: .milliseconds(100)) }
        guard tab.conversation != nil else {
            print("\(tab.title): no conversation")
            continue
        }
        let onDiff = tab.placedThreads.lazy.compactMap { thread in thread.comments.first { tab.canEdit($0.id) }.map { (thread, $0) } }.first
        if let (thread, comment) = onDiff {
            await tab.showInDiff(thread)
            if tab.threadActivity.unshown == nil {
                await tab.startEdit(of: comment.id)
                try? await Task.sleep(for: .milliseconds(1500))
                print("\(tab.title): editing \(comment.id) on the diff, \(String(describing: tab.commentEdits.edits[comment.id]?.phase))")
                let url = directory.appending(path: "edit-diff-\(title).png")
                try await saveSnapshot(of: window, to: url)
                written.append(url)
            } else {
                print("\(tab.title): \(comment.id) can't be shown in the diff")
                tab.threadActivity.dismissUnshown()
            }
            tab.cancelEdit(of: comment.id)
        } else {
            print("\(tab.title): no comment to edit on the diff")
        }
        tab.section = .conversation
        let page = ConversationPage.page(for: tab)
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline, !page.isLoaded { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(300))
        let found = try? await page.webView.evaluateJavaScript(
            "(() => { const link = document.querySelector('\(link)'); if (!link) return null; for (let thread = link.closest('details'); thread; thread = thread.parentElement.closest('details')) thread.open = true; link.scrollIntoView({ block: 'center' }); return link.dataset.editComment })()",
            in: nil, contentWorld: .defaultClient
        )
        guard let commentId = found as? String else {
            print("\(tab.title): no \(link) to click")
            continue
        }
        try? await Task.sleep(for: .milliseconds(500))
        _ = try? await page.webView.evaluateJavaScript("document.querySelector('\(link)').click()", in: nil, contentWorld: .defaultClient)
        try? await Task.sleep(for: .milliseconds(1500))
        let edits = tab.commentEdits
        print("\(tab.title): clicked Edit of \(commentId); editing over the conversation \(edits.editingInConversation ?? "none"), \(String(describing: edits.edits[commentId]?.phase)), \(page.editPopover == nil ? "no popover" : "in a popover by the link")")
        if let popover = page.editPopover?.popover {
            placePopover(under: page.webView.convert(popover.positioningRect, to: nil), in: window)
        }
        let url = directory.appending(path: "edit-\(title).png")
        try await saveSnapshot(of: window, to: url)
        page.closeEdit()
        tab.cancelEdit(of: commentId)
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// On each PR, selects text in a comment and presses `r`, sent to the key handling as a
/// synthesised key down, three times: in the conversation's first comment on the PR (or its
/// description), in the first comment of its first open thread there, and in the first comment
/// of a thread on the diff the viewer can reply to, triple-clicked. Each prints the draft and writes
/// `quote-comment-`, `quote-thread-` and `quote-diff-<title>.png`, with a popover moved back by
/// its link. Nothing is sent, and each draft is dropped afterwards.
@MainActor
private func saveSnapshotsOfQuotes(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    func pressR() -> Bool {
        guard let key = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: "r", charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15
        ) else { return false }
        return ReviewWindows.shared.quote(key, in: window)
    }
    for tab in windows.tabs.tabs {
        let title = sanitised(windows.title(of: tab.id))
        windows.select(tab.id)
        let fetched = Date.now.addingTimeInterval(20)
        while Date.now < fetched, tab.conversation == nil || tab.isFetchingConversation { try? await Task.sleep(for: .milliseconds(100)) }
        guard tab.conversation != nil else {
            print("\(tab.title): no conversation")
            continue
        }
        tab.section = .conversation
        let page = ConversationPage.page(for: tab)
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline, !page.isLoaded { try? await Task.sleep(for: .milliseconds(100)) }
        try? await Task.sleep(for: .milliseconds(300))
        let bodies = [
            ("comment", "document.querySelector('article.item.comment > .card > .body') ?? document.querySelector('article.item > .card > .body')"),
            ("thread", "document.querySelector('details.thread[open][data-thread-id] .thread-comment .body')"),
        ]
        for (kind, finding) in bodies {
            // Selects the body's first few blocks, as a drag over them would.
            let script = """
                (() => {
                  const body = \(finding);
                  if (!body) return null;
                  body.scrollIntoView({ block: 'center' });
                  const range = document.createRange();
                  const blocks = [...body.children];
                  if (blocks.length > 0) {
                    range.setStartBefore(blocks[0]);
                    range.setEndAfter(blocks[Math.min(blocks.length, 3) - 1]);
                  } else {
                    range.selectNodeContents(body);
                  }
                  const selection = window.getSelection();
                  selection.removeAllRanges();
                  selection.addRange(range);
                  return selection.toString();
                })()
                """
            guard let text = try? await page.webView.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient) as? String else {
                print("\(tab.title): no \(kind) body to select in the conversation")
                continue
            }
            window.makeFirstResponder(page.webView)
            let taken = pressR()
            try? await Task.sleep(for: .milliseconds(1500))
            let activity = tab.threadActivity
            let reply = activity.replyingInConversation.flatMap { activity.replies[$0] }
            let draft = reply ?? tab.conversationComment.draft
            print("\(tab.title): selected \(text.debugDescription) in a \(kind); r taken \(taken); into \(reply != nil ? "the thread's reply" : tab.conversationComment.isOpen ? "the comment on the PR" : "nothing"): \((draft?.text ?? "none").debugDescription)")
            if let popover = page.replyPopover?.popover ?? page.commentPopover {
                placePopover(under: page.webView.convert(popover.positioningRect, to: nil), in: window)
            }
            let url = directory.appending(path: "quote-\(kind)-\(title).png")
            try await saveSnapshot(of: window, to: url)
            written.append(url)
            page.closeReply()
            page.closeComment()
            if let id = activity.replyingInConversation, let thread = tab.reviewThread(id) { tab.cancelReply(to: thread) }
            tab.cancelConversationComment()
            _ = try? await page.webView.evaluateJavaScript("window.getSelection().removeAllRanges()", in: nil, contentWorld: .defaultClient)
        }
        guard let thread = tab.placedThreads.first(where: { $0.viewerCanReply && !$0.isPending && !$0.isResolved && !$0.comments.isEmpty }) else {
            print("\(tab.title): no thread on the diff to quote")
            continue
        }
        await tab.showInDiff(thread)
        try? await Task.sleep(for: .milliseconds(1500))
        window.layoutIfNeeded()
        // A comment body's text is a selectable field drawn over its marker.
        guard let root = window.contentView,
              let field = descendants(of: root).lazy.compactMap({ $0 as? NSTextField }).first(where: { field in
                  !field.isHiddenOrHasHiddenAncestor && !field.isEditable && field.isSelectable && !field.stringValue.isEmpty
                      && descendants(of: root).contains { marker in
                          marker is QuoteSource.Marker && marker.convert(marker.bounds, to: nil).contains(field.convert(NSPoint(x: field.bounds.midX, y: field.bounds.midY), to: nil))
                      }
              })
        else {
            print("\(tab.title): no comment body drawn on the diff")
            continue
        }
        // A triple click selects the paragraph, as it would for a reader.
        let point = field.convert(NSPoint(x: min(20, field.bounds.midX), y: field.bounds.midY), to: nil)
        for clickCount in 1...3 {
            let events = [NSEvent.EventType.leftMouseUp, .leftMouseDown].compactMap { type in
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: type == .leftMouseDown ? 1 : 0)
            }
            guard events.count == 2 else { continue }
            NSApp.postEvent(events[0], atStart: false)
            window.sendEvent(events[1])
            try? await Task.sleep(for: .milliseconds(50))
        }
        try? await Task.sleep(for: .milliseconds(300))
        let taken = pressR()
        try? await Task.sleep(for: .milliseconds(800))
        let draft = tab.threadActivity.replies[thread.id]
        print("\(tab.title): selected \(String(field.stringValue.prefix(60)).debugDescription) on the diff; r taken \(taken); reply: \((draft?.text ?? "none").debugDescription), focus in \(window.firstResponder.map { String(describing: type(of: $0)) } ?? "nothing")")
        let url = directory.appending(path: "quote-diff-\(title).png")
        try await saveSnapshot(of: window, to: url)
        written.append(url)
        tab.cancelReply(to: thread)
    }
    windows.select(selected)
    return written
}

/// On each PR's conversation, scrolls its first reaction pill into the middle of the view, or
/// the first comment's reactions if no one has reacted, its thread unfolded, opens the picker
/// beside it, and writes
/// `reactions-<title>.png`.
@MainActor
private func saveSnapshotsOfReactions(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs where tab.conversation != nil {
        tab.section = .conversation
        windows.select(tab.id)
        let page = ConversationPage.page(for: tab)
        let deadline = Date.now.addingTimeInterval(10)
        while Date.now < deadline, !page.isLoaded { try? await Task.sleep(for: .milliseconds(100)) }
        let found = try? await page.webView.evaluateJavaScript(
            "(() => { const pill = document.querySelector('a.reaction'); const row = pill ? pill.closest('.reactions') : document.querySelector('.reactions'); if (!row) return 'none'; for (let thread = row.closest('details'); thread; thread = thread.parentElement.closest('details')) thread.open = true; row.scrollIntoView({ block: 'center' }); row.querySelector('details').open = true; return pill ? 'pills' : 'no pills' })()",
            in: nil, contentWorld: .defaultClient
        )
        print("\(tab.title): reactions \(found as? String ?? "unknown")")
        try? await Task.sleep(for: .milliseconds(500))
        let url = directory.appending(path: "reactions-\(sanitised(windows.title(of: tab.id))).png")
        try await saveSnapshot(of: window, to: url)
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// Opens the checks popover on the topmost checks glyph of the lists and of each PR, and writes
/// the window with it open as `checks-<title>.png`.
@MainActor
private func saveSnapshotsOfChecks(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for id in [nil] + windows.tabs.tabs.map(\.id) {
        windows.select(id)
        try? await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        guard let root = window.contentView,
              let anchor = descendants(of: root).lazy.compactMap({ $0 as? HoverPopoverAnchor.AnchorView })
                  .filter({ !$0.isHiddenOrHasHiddenAncestor })
                  .min(by: { readsBefore($0, $1) })
        else {
            print("\(windows.title(of: id)) shows no checks glyph")
            continue
        }
        anchor.showPopover()
        try? await Task.sleep(for: .milliseconds(300))
        placePopover(under: anchor, in: window)
        let url = directory.appending(path: "checks-\(sanitised(windows.title(of: id))).png")
        try await saveSnapshot(of: window, to: url)
        anchor.closePopover()
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// For each PR, once its conversation has settled and its diff has been counted, prints the
/// viewer's verdict and, where the header shows it, opens its popover as resting on it would,
/// writing `verdict-<title>.png`.
@MainActor
private func saveSnapshotsOfVerdicts(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs {
        windows.select(tab.id)
        let deadline = ContinuousClock.now + .seconds(10)
        while !tab.isConversationSettled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let title = windows.title(of: tab.id)
        guard let verdict = tab.viewerVerdict else {
            print("\(title): no verdict of the viewer's")
            continue
        }
        print("\(title): \(verdict.state.rawValue) on \(verdict.commitOid.map { String($0.prefix(7)) } ?? "?"), \(verdict.since.map(\.description) ?? "since unknown"), \(tab.canReview ? "shown" : "not shown, as the viewer can't review it")")
        try? await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        guard let root = window.contentView,
              let anchor = descendants(of: root).lazy.compactMap({ $0 as? HoverPopoverAnchor.AnchorView })
                  .first(where: { !$0.isHiddenOrHasHiddenAncestor && ($0.content as? HoverHelp)?.title.hasPrefix("You ") == true })
        else { continue }
        anchor.showPopover()
        try? await Task.sleep(for: .milliseconds(300))
        placePopover(under: anchor, in: window)
        let url = directory.appending(path: "verdict-\(sanitised(title)).png")
        try await saveSnapshot(of: window, to: url)
        anchor.closePopover()
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// For each PR with CI's visual review in its conversation, prints it, opens the header flag's
/// popover as resting on it would and writes `visual-badge-<title>.png`, then clicks the sidebar's
/// Visual review row through the window as the mouse would, writes `visual-downloading-<title>.png`
/// if its artifacts download, waits until the report has loaded or failed, prints which, and
/// writes `visual-<title>.png`.
@MainActor
private func saveSnapshotsOfVisualReviews(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs {
        windows.select(tab.id)
        let deadline = ContinuousClock.now + .seconds(10)
        while !tab.isConversationSettled, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(250))
        }
        let title = windows.title(of: tab.id)
        guard let review = tab.visualReview else {
            print("\(title): no visual review")
            continue
        }
        let stories = review.stories.map { "\($0.name) \($0.status.label)" }.joined(separator: ", ")
        print("\(title): visual review \(review.summary ?? "uncounted"), rendered \(review.rendered.map { "\($0.count) of \($0.total)" } ?? "unknown"), updated \(review.updatedAt), report \(review.reportURL.absoluteString), stories [\(stories)]")
        try? await Task.sleep(for: .milliseconds(300))
        window.layoutIfNeeded()
        guard let root = window.contentView else { continue }
        if let anchor = descendants(of: root).lazy.compactMap({ $0 as? HoverPopoverAnchor.AnchorView })
            .first(where: { !$0.isHiddenOrHasHiddenAncestor && $0.content is VisualReviewPopover }) {
            anchor.showPopover()
            try? await Task.sleep(for: .milliseconds(300))
            placePopover(under: anchor, in: window)
            let url = directory.appending(path: "visual-badge-\(sanitised(title)).png")
            try await saveSnapshot(of: window, to: url)
            anchor.closePopover()
            written.append(url)
        } else {
            print("\(title): no visual changes flag in the header")
        }
        guard let row = descendants(of: root).first(where: { $0 is VisualReviewRowMarker.Marker && !$0.isHiddenOrHasHiddenAncestor }) else {
            print("\(title): no Visual review row")
            continue
        }
        let point = row.convert(NSPoint(x: row.bounds.midX, y: row.bounds.midY), to: nil)
        let before = tab.section
        // The mouse-up is queued first, so a tracking loop started by the mouse-down finds it.
        let events = [NSEvent.EventType.leftMouseUp, .leftMouseDown].compactMap { type in
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard events.count == 2 else { continue }
        NSApp.postEvent(events[0], atStart: false)
        window.sendEvent(events[1])
        try? await Task.sleep(for: .milliseconds(300))
        print("clicking Visual review at \(point) switched \(title) from \(before) to \(tab.section)")
        // A first open downloads the job's artifacts, which takes minutes; its progress is
        // snapshotted once files are arriving, then printed now and then until it's done.
        let started = ContinuousClock.now
        var downloadShot = false
        var lastPrinted = started
        while ContinuousClock.now < started + .seconds(600), let page = VisualReviewPage.existingPage(for: tab), page.isDownloading {
            if case let .downloading(progress) = page.cover {
                if !downloadShot, progress.done > 0 {
                    downloadShot = true
                    let url = directory.appending(path: "visual-downloading-\(sanitised(title)).png")
                    try await saveSnapshot(of: window, to: url)
                    written.append(url)
                }
                if ContinuousClock.now - lastPrinted > .seconds(10) {
                    lastPrinted = .now
                    print("\(title): downloading, \(progress.description) after \(ContinuousClock.now - started)")
                }
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        let loaded = ContinuousClock.now + .seconds(20)
        while ContinuousClock.now < loaded, VisualReviewPage.existingPage(for: tab).map({ $0.cover == .loading }) ?? true {
            try? await Task.sleep(for: .milliseconds(250))
        }
        print("\(title): report settled after \(ContinuousClock.now - started)")
        // Lets the page draw a frame once loaded.
        try? await Task.sleep(for: .milliseconds(500))
        if let page = VisualReviewPage.existingPage(for: tab) {
            let state = switch page.cover {
            case nil: "loaded"
            case .loading: "still loading"
            case let .downloading(progress): "still downloading, \(progress.description)"
            case let .failed(failure): "failed: \(failure.title)"
            }
            print("\(title): report \(state) at \(page.webView.url?.absoluteString ?? "nothing"), titled \(page.webView.title ?? "nothing")")
        }
        let url = directory.appending(path: "visual-\(sanitised(title)).png")
        try await saveSnapshot(of: window, to: url)
        written.append(url)
    }
    windows.select(selected)
    return written
}

/// Pulls each PR's shown diff `travel` past its end with trackpad scroll events sent through the
/// scroll view, as the fingers would, from the diff scrolled to its end and at rest. Writes
/// `pull-<title>.png` halfway and `armed-<title>.png` at the end, scrolls `back` that far if
/// asked, and lets go, printing the pull and the clip view's bounds after each step.
@MainActor
private func saveSnapshotsOfPulls(_ travel: CGFloat, back: CGFloat, in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow, let root = window.contentView else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs {
        windows.select(tab.id)
        try? await Task.sleep(for: .milliseconds(500))
        window.layoutIfNeeded()
        guard let scroll = descendants(of: root).lazy.compactMap({ $0 as? OverscrollScrollView }).first(where: { !$0.isHiddenOrHasHiddenAncestor }) else { continue }
        let title = sanitised(windows.title(of: tab.id))
        let clip = scroll.contentView
        // Laying out the end can make a long document taller, so scroll again until it's there.
        for _ in 0..<10 {
            let far = NSRect(x: clip.bounds.minX, y: clip.documentRect.maxY + clip.contentInsets.bottom, width: clip.bounds.width, height: clip.bounds.height)
            let end = clip.constrainBoundsRect(far).origin
            if end == clip.bounds.origin { break }
            clip.scroll(to: end)
            scroll.reflectScrolledClipView(clip)
            try? await Task.sleep(for: .milliseconds(200))
        }
        printPull(of: scroll, when: "\(title) at rest")
        sendScroll(.began, by: 0, to: scroll, printing: true)
        await dragScroll(travel / 2, on: scroll)
        printPull(of: scroll, when: "halfway")
        let halfway = directory.appending(path: "pull-\(title).png")
        try await saveSnapshot(of: window, to: halfway)
        await dragScroll(travel / 2, on: scroll)
        printPull(of: scroll, when: "pulled")
        let pulled = directory.appending(path: "armed-\(title).png")
        try await saveSnapshot(of: window, to: pulled)
        if back > 0 {
            await dragScroll(-back, on: scroll)
            printPull(of: scroll, when: "scrolled back")
        }
        sendScroll(.ended, by: 0, to: scroll)
        printPull(of: scroll, when: "let go")
        try? await Task.sleep(for: .milliseconds(500))
        printPull(of: scroll, when: "settled")
        written += [halfway, pulled]
    }
    windows.select(selected)
    return written
}

/// A trackpad's scroll phases, as `CGEventField.scrollWheelEventScrollPhase` takes them.
private enum ScrollPhase: Int64 {
    case began = 1
    case changed = 2
    case ended = 4
}

/// Moves the fingers `distance` points over the trackpad in small steps a few milliseconds apart,
/// positive pulling the content up past the end.
@MainActor
private func dragScroll(_ distance: CGFloat, on scroll: NSScrollView) async {
    let step: CGFloat = 4
    var left = abs(distance)
    while left > 0 {
        let moved = min(step, left)
        sendScroll(.changed, by: distance < 0 ? -moved : moved, to: scroll, printing: left == abs(distance))
        left -= moved
        try? await Task.sleep(for: .milliseconds(8))
    }
}

/// Sends a continuous scroll event, as a trackpad makes, through the scroll view's
/// `scrollWheel(with:)`. The event's own delta is the content's movement, so pulling past the
/// end is negative.
@MainActor
private func sendScroll(_ phase: ScrollPhase, by pull: CGFloat, to scroll: NSScrollView, printing: Bool = false) {
    let delta = Int32(-pull.rounded())
    guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: delta, wheel2: 0, wheel3: 0) else { return }
    cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
    cg.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
    cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(delta))    // Stamped now, as a source-less event isn't, so the pull's dwell sees real time.
    cg.timestamp = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    guard let event = NSEvent(cgEvent: cg) else { return }
    if printing {
        print("  event: phase \(event.phase.rawValue) precise \(event.hasPreciseScrollingDeltas) scrollingDeltaY \(event.scrollingDeltaY) timestamp \(event.timestamp) uptime \(ProcessInfo.processInfo.systemUptime)")
    }
    scroll.scrollWheel(with: event)
}

@MainActor
private func printPull(of scroll: OverscrollScrollView, when: String) {
    let pull = scroll.currentPull()
    let clip = scroll.contentView
    let progress = String(format: "%.2f", pull.progress)
    print("  \(when): travel \(pull.travel) revealed \(pull.revealed) progress \(progress) armed \(pull.isArmed) dragging \(pull.isDragging) | clip y \(clip.bounds.minY) maxY \(clip.bounds.maxY) document maxY \(clip.documentRect.maxY) inset \(clip.contentInsets.bottom)")
}

/// Shows each PR's files and writes `whitespace-shown-<title>.png` and
/// `whitespace-hidden-<title>.png` of its shown file, printing each file's counts and hunks
/// each way. Whitespace stays hidden after.
@MainActor
private func saveSnapshotsOfWhitespace(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs {
        guard case .ready = tab.phase else { continue }
        tab.section = .files
        windows.select(tab.id)
        let title = sanitised(windows.title(of: tab.id))
        for hides in [false, true] {
            await tab.setHidesWhitespace(hides)
            print("\(tab.title) \(hides ? "hiding" : "showing") whitespace:")
            if case let .ready(changes)? = tab.shownChanges {
                for file in changes.files {
                    print("  \(file.path) +\(file.additions) −\(file.deletions), \(file.hunks.count) hunks\(file.isWhitespaceOnly ? ", whitespace-only changes" : "")")
                }
            }
            try? await Task.sleep(for: .milliseconds(500))
            let url = directory.appending(path: "whitespace-\(hides ? "hidden" : "shown")-\(title).png")
            try await saveSnapshot(of: window, to: url)
            written.append(url)
        }
    }
    windows.select(selected)
    return written
}

/// Shows each PR's shown image file once both its versions are read, an SVG rendered, and
/// writes `image-<mode>-<title>.png` for each way of comparing a changed one, or
/// `image-<title>.png` for an added or deleted one. A PR whose diff wasn't ready in the run's
/// wait is waited for, and given the commit and file asked for then.
@MainActor
private func saveSnapshotsOfImages(in windows: WindowManager, to directory: URL) async throws -> [URL] {
    guard let window = windows.mainWindow else { return [] }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let environment = ProcessInfo.processInfo.environment
    let selected = windows.tabs.selected
    var written: [URL] = []
    for tab in windows.tabs.tabs {
        let deadline = Date.now.addingTimeInterval(60)
        while Date.now < deadline, !tab.phase.isSettled(holding: nil) {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if let wanted = environment["LOUPE_SNAPSHOT_COMMIT"], case let .ready(review) = tab.phase,
           let commit = review.commits.picked(by: wanted), tab.shownChoice != .commit(commit.oid) {
            await tab.show(.commit(commit.oid))
        }
        if let wanted = environment["LOUPE_SNAPSHOT_FILE"], tab.shownFile.map({ !$0.path.contains(wanted) }) ?? true,
           case let .ready(changes)? = tab.shownChanges {
            if let file = changes.files.first(where: { $0.path.contains(wanted) }) {
                tab.selectedFile = file.id
            } else if let file = changes.hidden.first(where: { $0.path.contains(wanted) }) {
                tab.selectedFile = file.id
                await tab.diffHiddenFile(file.path)
            }
        }
        guard let file = tab.shownFile, let change = tab.imageChange(of: file) else { continue }
        tab.images.setRendered(true, path: file.path)
        await tab.loadImages(change)
        print("\(tab.title): \(file.path), old \(describe(change.old.flatMap { tab.images.image($0) })), new \(describe(change.new.flatMap { tab.images.image($0) }))")
        windows.select(tab.id)
        let title = sanitised(windows.title(of: tab.id))
        guard change.old != nil, change.new != nil else {
            let url = directory.appending(path: "image-\(title).png")
            try await saveSnapshot(of: window, to: url)
            written.append(url)
            continue
        }
        for mode in ImageComparisonMode.allCases {
            tab.images.setMode(mode, path: file.path)
            let url = directory.appending(path: "image-\(mode.rawValue)-\(title).png")
            try await saveSnapshot(of: window, to: url)
            written.append(url)
        }
        tab.images.setMode(.twoUp, path: file.path)
    }
    windows.select(selected)
    return written

    func describe(_ state: ImageState?) -> String {
        switch state {
        case nil: "none"
        case .loading: "loading"
        case let .ready(data): "\(data.count) bytes"
        case let .tooLarge(bytes): "too large at \(bytes) bytes"
        case let .failed(message): "failed: \(message)"
        }
    }
}

/// Lets the window settle and draw, then writes it to `url`.
@MainActor
private func saveSnapshot(of window: NSWindow, to url: URL) async throws {
    try? await Task.sleep(for: .milliseconds(300))
    window.layoutIfNeeded()
    window.displayIfNeeded()
    try pngData(await snapshot(window: window)).write(to: url)
}

private enum SnapshotError: Error, CustomStringConvertible {
    case noSuchTab(String)

    var description: String {
        switch self {
        case let .noSuchTab(wanted): "no tab strip item \(wanted) to click"
        }
    }
}

@MainActor
private func saveSnapshotOfKeyWindow() {
    guard let window = NSApp.keyWindow else { return }
    Task { saveSnapshot(await snapshot(window: window), of: window) }
}

@MainActor
private func saveSnapshot(_ image: NSImage, of window: NSWindow) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.nameFieldStringValue = "\(sanitised(window.title)).png"
    panel.beginSheetModal(for: window) { response in
        guard response == .OK, let url = panel.url else { return }
        MainActor.assumeIsolated {
            do {
                try pngData(image).write(to: url)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }
}

@MainActor
private func snapshotAllTabsToDesktop(_ windows: WindowManager) async {
    let stamp = Date.now.formatted(.iso8601.dateSeparator(.dash).timeSeparator(.omitted).timeZoneSeparator(.omitted))
    let directory = URL.desktopDirectory.appending(path: "Loupe Snapshots \(stamp)", directoryHint: .isDirectory)
    do {
        _ = try await saveSnapshotsOfAllTabs(in: windows, to: directory)
        NSWorkspace.shared.activateFileViewerSelecting([directory])
    } catch {
        NSAlert(error: error).runModal()
    }
}

/// Draws each visible web view under `root` onto `rep`, which holds `root` as drawn.
@MainActor
private func drawWebViews(in root: NSView, onto rep: NSBitmapImageRep) async {
    for webView in descendants(of: root).compactMap({ $0 as? WKWebView }) where !webView.isHiddenOrHasHiddenAncestor {
        guard let image = try? await webView.takeSnapshot(configuration: nil) else { continue }
        var rect = webView.convert(webView.bounds, to: root)
        if root.isFlipped { rect.origin.y = root.bounds.height - rect.maxY }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Moves the open popover to just under `view`, as on screen. The window is off every screen
/// during a snapshot run, so AppKit has moved the popover onto one, away from it.
@MainActor
private func placePopover(under view: NSView, in window: NSWindow) {
    placePopover(under: view.convert(view.bounds, to: nil), in: window)
}

/// Moves the open popover to just under `anchor`, in the window's coordinates, or just over it
/// when there's no room under it, as AppKit does on screen.
@MainActor
private func placePopover(under anchor: NSRect, in window: NSWindow) {
    guard let popover = window.childWindows?.first(where: \.isVisible) else { return }
    let x = min(max(anchor.midX - popover.frame.width / 2, 0), window.frame.width - popover.frame.width)
    let top = anchor.minY >= popover.frame.height ? anchor.minY : anchor.maxY + popover.frame.height
    popover.setFrameTopLeftPoint(NSPoint(x: window.frame.minX + x, y: window.frame.minY + top))
}

/// Draws the content of `window`'s visible child windows, such as an open popover, and theirs in
/// turn, over where they sit on `base` onto `rep`, which holds `base` as drawn. A popover's frame
/// is a material that doesn't draw off screen, so a plain rounded panel stands in for it.
@MainActor
private func drawChildWindows(of window: NSWindow, onto rep: NSBitmapImageRep, over base: NSWindow? = nil) {
    let base = base ?? window
    // Sheets too, which aren't child windows.
    for child in (window.childWindows ?? []) + [window.attachedSheet].compactMap({ $0 }) where child.isVisible {
        defer { drawChildWindows(of: child, onto: rep, over: base) }
        guard let view = child.contentView, let image = render(view) else { continue }
        let inChild = view.convert(view.bounds, to: nil)
        let rect = inChild.offsetBy(dx: child.frame.minX - base.frame.minX, dy: child.frame.minY - base.frame.minY)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let panel = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        NSColor.windowBackgroundColor.setFill()
        panel.fill()
        NSColor.separatorColor.setStroke()
        panel.stroke()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// Whether `view` reads before `other`: higher in the window, or level with it and to its left.
@MainActor
private func readsBefore(_ view: NSView, _ other: NSView) -> Bool {
    let (a, b) = (view.convert(view.bounds, to: nil), other.convert(other.bounds, to: nil))
    return abs(a.maxY - b.maxY) < 20 ? a.minX < b.minX : a.maxY > b.maxY
}

@MainActor
func descendants(of view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
}

/// The view drawn at the window's backing scale, or nil if it draws nothing.
@MainActor
private func render(_ view: NSView) -> NSBitmapImageRep? {
    guard !view.bounds.isEmpty, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
    view.cacheDisplay(in: view.bounds, to: rep)
    return rep
}

@MainActor
private func pngData(_ image: NSImage) throws -> Data {
    guard let rep = image.representations.lazy.compactMap({ $0 as? NSBitmapImageRep }).first,
          let data = rep.representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    return data
}

/// `title` with anything but letters, digits and `-` replaced, safe as a file name.
private func sanitised(_ title: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
    let replaced = String(title.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
    return replaced.isEmpty ? "window" : replaced
}

private extension [PullRequestCommit] {
    /// The commit `wanted` names: a 1-based index if it's a short number, else an oid prefix.
    func picked(by wanted: String) -> PullRequestCommit? {
        if wanted.count < 4, let index = Int(wanted) {
            return indices.contains(index - 1) ? self[index - 1] : nil
        }
        return first { $0.oid.hasPrefix(wanted) }
    }
}

private extension PullRequestTab {
    /// The selected file's diff in the shown changes, hidden or not, once diffed.
    var shownFile: FileDiff? {
        guard case let .ready(changes)? = shownChanges, let selectedFile else { return nil }
        if let file = changes.files.first(where: { $0.id == selectedFile }) { return file }
        if case let .ready(diff)? = hiddenFileDiff(of: selectedFile) { return diff }
        return nil
    }
}

private extension ReviewSection {
    /// The section `LOUPE_SNAPSHOT_TAB` names.
    init?(named name: String) {
        switch name {
        case "conversation": self = .conversation
        case "files": self = .files
        case "visual": self = .visualReview
        case "circleci": self = .circleCI
        default: return nil
        }
    }
}

private extension ReviewPhase {
    /// Done, one way or another, or held at `held` to be drawn.
    func isSettled(holding held: DiffStep?) -> Bool {
        switch self {
        case .ready, .failed, .noCheckout: true
        case let .producing(step): step == held
        }
    }
}

/// Holds git work at one step for good, from when it's set, so a snapshot run can draw what
/// shows meanwhile. The run quits without ever letting it go.
@MainActor
private final class StepHold {
    var step: DiffStep?

    init(step: DiffStep?) {
        self.step = step
    }

    func wait(at reached: DiffStep) async {
        guard reached == step else { return }
        try? await Task.sleep(for: .seconds(3600))
    }
}

/// What the shown tab is, once a link has been opened: the link's tab waiting or failed, or the
/// PR's own.
@MainActor
private func linkState(in tabs: TabsModel) -> String {
    switch tabs.selected.flatMap(tabs.item(id:)) {
    case let .pending(pending)?: pending.error.map { "failed: \($0)" } ?? "looking up, held"
    case let .pullRequest(tab)?: "opened \(tab.title)"
    case nil: "nothing shown"
    }
}

/// Sends requests to GitHub until started, then holds every one unanswered for good; asked to,
/// it holds every conversation fetch, or every lookup of a PR by number, from the outset.
private final class GitHubHold: HTTPTransport {
    private let isHolding = OSAllocatedUnfairLock(initialState: false)
    private let holdsConversations: Bool
    private let holdsNumberLookups: Bool

    init(holdsConversations: Bool, holdsNumberLookups: Bool) {
        self.holdsConversations = holdsConversations
        self.holdsNumberLookups = holdsNumberLookups
    }

    func start() {
        isHolding.withLock { $0 = true }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if isHolding.withLock({ $0 }) || holdsConversations && isConversationFetch(request) || holdsNumberLookups && isNumberLookup(request) {
            try await Task.sleep(for: .seconds(3600))
        }
        return try await SnapshotRun.readOnlyGitHub.send(request)
    }
}

/// Sends reads to GitHub and never a write. An asynchronous merge is answered as GitHub's docs
/// show, accepted and then still running whenever asked after; any other REST write or GraphQL
/// mutation is held unanswered for good.
private final class MergeRehearsal: HTTPTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = request.url ?? URL(filePath: "/")
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        if url.path().contains("/merge-async") {
            let pending = #"{"status":"pending","details":{"message":"Merge request is in progress.","uuid":"rehearsal","merge_method":"merge","merge_action":"direct_merge","expected_head_sha":""}}"#
            let status = request.httpMethod == "PUT" ? 202 : 200
            return (Data(pending.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil) ?? HTTPURLResponse())
        }
        let isWrite = request.httpMethod != "GET" && url.path() != "/graphql" && url.path() != "/markdown"
        if isWrite || body.contains("mutation") {
            try await Task.sleep(for: .seconds(3600))
        }
        return try await SnapshotRun.readOnlyGitHub.send(request)
    }
}

/// Whether the request looks a PR up by its repo and number, as for a link.
private func isNumberLookup(_ request: URLRequest) -> Bool {
    guard let body = request.httpBody else { return false }
    return String(decoding: body, as: UTF8.self).contains("pullRequest(number:")
}

/// Whether the request asks for a page of a PR's conversation, the only queries that spread its
/// timeline fragment.
private func isConversationFetch(_ request: URLRequest) -> Bool {
    guard let body = request.httpBody else { return false }
    return String(decoding: body, as: UTF8.self).contains("...TimelinePage")
}

private extension DiffStep {
    init?(named name: String) {
        switch name {
        case "resolving": self = .resolvingCheckout
        case "fetching": self = .fetching
        case "diffing": self = .diffing
        default: return nil
        }
    }
}

/// What the PR's "Open in" button would do: the editor, branch and checkout, and whether the
/// checkout is clean enough to switch, found with read-only git.
@MainActor
private func editorPlan(for tab: PullRequestTab) async -> String {
    let pullRequest = tab.pullRequest
    guard let checkout = tab.editorCheckout, let editor = tab.editor else {
        return "\(tab.title): editor: no checkout resolved, button disabled"
    }
    let state: String
    do {
        try await CheckoutSwitcher().ensureClean(checkout)
        state = "clean"
    } catch {
        state = "refused: \(error.localizedDescription)"
    }
    return "\(tab.title): editor: \(editor.name), branch \(pullRequest.headRefName), checkout \(checkout.path(percentEncoded: false)), \(state)"
}

/// Each earlier head the tab offers the changes since, and whether they can be shown.
@MainActor
private func printAnchors(of tab: PullRequestTab) {
    for anchor in tab.anchors {
        let head = anchor.head.map { " to \($0.prefix(7))" } ?? ""
        print("\(tab.title): since \(anchor.kind) at \(anchor.oid.prefix(7))\(head): \(tab.anchorState(of: anchor).map(String.init(describing:)) ?? "not looked at")")
    }
}

/// Which changes the tab shows, their files, and those that couldn't be told apart from a rebase.
@MainActor
private func printShownChanges(of tab: PullRequestTab) {
    let files = if case let .ready(changes)? = tab.shownChanges { changes.files.map(\.path).joined(separator: ", ") } else { "not diffed" }
    let unseparated = tab.unseparatedPaths.sorted().joined(separator: ", ")
    print("\(tab.title): showing \(tab.shownChoice), section \(tab.section), files \(files), unseparated [\(unseparated)], stat \(tab.diffStat(of: tab.shownChoice).map(String.init(describing:)) ?? "none")")
}

/// A comment longer than any markdown box grows to, for `LOUPE_SNAPSHOT_DRAFT=long`.
private let longDraft = (1...4).map { "\($0). \(sampleDraft)" }.joined(separator: "\n\n")

/// Sends a key equivalent to `window` as AppKit delivers one, before the menus.
@MainActor
private func pressKeyEquivalent(_ key: String, modifiers: NSEvent.ModifierFlags, keyCode: UInt16, in window: NSWindow) {
    guard let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode
    ) else { return }
    _ = window.performKeyEquivalent(with: event)
}

/// A comment for `LOUPE_SNAPSHOT_PREVIEW` to preview, with the markdown comments use most.
private let sampleDraft = """
    Looks good, two small things:

    - Rename `fetchAll`, as it only gets **one page**
    - Keep the retry; see [GitHub's REST docs](https://docs.github.com/en/rest)

    ```go
    page, err := client.FetchPage(ctx, cursor)
    ```
    """

/// `<line>`, or `<first>-<last>`, as a snapshot hook names lines.
private func snapshotLines(_ value: String) -> ClosedRange<Int>? {
    let parts = value.split(separator: "-").compactMap { Int($0) }
    switch parts.count {
    case 1: return parts[0]...parts[0]
    case 2 where parts[0] <= parts[1]: return parts[0]...parts[1]
    default: return nil
    }
}

/// Where a comment being started is, as a snapshot run prints it.
@MainActor
private func describe(_ comment: NewComment) -> String {
    let start = comment.start.map { "from \($0.side) line \($0.line) " } ?? ""
    let commit = comment.target.isWholePullRequest ? "the whole PR's diff" : comment.target.isOnHead ? "the changes since" : "commit \(comment.target.commitOid.prefix(7))"
    return "a comment is open \(start)on \(comment.anchor.side) line \(comment.anchor.line) of \(commit), reviews \(comment.takesReviewComments ? "offered" : "not offered")"
}
