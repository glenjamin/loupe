import AppKit
import LoupeFakeGitHub
import LoupeGit
import LoupeInbox
import LoupeModel
import os

/// `LOUPE_SNAPSHOT_SCRIPT=<file>` drives a snapshot run from a script, one step a line: it opens
/// PRs, clicks, hovers, presses keys and types through the app's own event handling, finds what to
/// act on in the accessibility tree, asserts what it finds there, and writes PNGs. Each step's
/// result is printed; the first failure writes `failure.png`, prints what was expected beside
/// the part of the tree it looked in, and quits with status 1. `NOTES.md` has the step reference.
@MainActor
final class SnapshotScript {
    static let file = SnapshotRun.directory == nil ? nil : ProcessInfo.processInfo.environment["LOUPE_SNAPSHOT_SCRIPT"].map { URL(filePath: $0) }

    private let windows: WindowManager
    private let directory: URL
    /// Where the pointer last moved to, so moving it away can say it left.
    private var pointer: (window: NSWindow, point: NSPoint)?
    /// Where the pointer last moved to on screen, for windows to report as the mouse's location.
    private static var pointerOnScreen: NSPoint?
    /// The frame of what was last clicked, in the main window, which a popover it opened hangs from.
    private var anchor: NSRect?
    /// The menu the last right-click asked for, which `choose` picks from.
    private var menu: NSMenu?
    /// The tracking areas the pointer is in, which it tells when it leaves.
    private var hovered: [(view: NSView, area: NSTrackingArea)] = []

    /// Has SwiftUI build its accessibility tree, as it does only once an assistive app asks the
    /// app for it, so a script can find what's drawn. Called before any window is made, as views
    /// drawn before then aren't in it.
    static func exposeAccessibility() {
        guard file != nil else { return }
        // The setter is the old API's, which assistive apps reach through the accessibility server.
        let set = NSSelectorFromString("accessibilitySetValue:forAttribute:")
        for attribute in ["AXEnhancedUserInterface", "AXManualAccessibility"] where NSApp.responds(to: set) {
            _ = NSApp.perform(set, with: NSNumber(value: true), with: attribute)
        }
    }

    private init(windows: WindowManager, directory: URL) {
        self.windows = windows
        self.directory = directory
    }

    /// Runs the script and quits: with status 0 when every step passed, 1 at the first that
    /// didn't, and 2 when the script can't be read.
    static func run(_ file: URL, windows: WindowManager, directory: URL) async -> Never {
        // Each step's line as it happens, even into a pipe, so a slow step can be seen.
        setvbuf(stdout, nil, _IOLBF, 0)
        // A script stuck behind something modal still ends, and says so.
        DispatchQueue.global().asyncAfter(deadline: .now() + 600) {
            print("FAIL the script ran for over 10 minutes")
            exit(1)
        }
        let lines: [ScriptLine]
        do {
            lines = try ScriptLine.parse(String(contentsOf: file, encoding: .utf8))
        } catch {
            print("FAIL \(file.path(percentEncoded: false)): \(error)")
            exit(2)
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = SnapshotScript(windows: windows, directory: directory)
        for line in lines {
            do {
                let note = try await script.perform(line.step)
                print("ok   \(line.number): \(line.text)\(note.map { " — \($0)" } ?? "")")
            } catch let failure as StepFailure {
                await script.report(failure, at: line)
                exit(1)
            } catch {
                await script.report(StepFailure(expected: line.text, found: "\(error)"), at: line)
                exit(1)
            }
        }
        // Against the fixtures, a request no fake could answer fails the run, though the app
        // carried on, so nothing quietly depends on GitHub.
        let unanswered = FakeGitHubMismatch.recorded
        guard unanswered.isEmpty else {
            print("FAIL the fake GitHub couldn't answer every request:\n\(unanswered.joined(separator: "\n"))")
            exit(1)
        }
        print("passed \(lines.count) steps")
        exit(0)
    }

    /// Performs a step, returning anything worth printing beside its result; throws
    /// `StepFailure` when it can't be done or what it asserts doesn't hold.
    private func perform(_ step: Step) async throws -> String? {
        switch step {
        case let .open(target):
            return try await open(target)
        case let .pause(duration):
            try? await Task.sleep(for: duration)
            return nil
        case let .settle(timeout):
            return try await settle(within: timeout)
        case let .waitUntil(query, predicate, timeout):
            let deadline = Date.now + timeout.timeInterval
            while true {
                // Drawn first, as a screen would between polls, so updates made in drawing land.
                for window in shownWindows() {
                    window.layoutIfNeeded()
                    window.displayIfNeeded()
                }
                let found = check(query, predicate)
                if found.holds { return found.note }
                if Date.now >= deadline {
                    throw StepFailure(expected: "\(query) \(predicate) within \(timeout)", found: found.note, scope: query)
                }
                try? await Task.sleep(for: .milliseconds(25))
            }
        case let .click(query, kind):
            let node = try find(query)
            anchor = node.window === windows.mainWindow ? node.frame : anchor
            if kind == .right { return try rightClick(node) }
            await click(node, twice: kind == .double, modifiers: kind == .shift ? .shift : [])
            await settleInput()
            return "at \(describe(node.centre)) in \(node.windowName)"
        case let .hover(query, offset):
            let node = try find(query)
            // A hover popover hangs from what it's over, as a click's does.
            anchor = node.window === windows.mainWindow ? node.frame : anchor
            let point = NSPoint(x: node.centre.x + offset.dx, y: node.centre.y + offset.dy)
            movePointer(to: point, in: node.window)
            await settleInput()
            return "pointer at \(describe(point))"
        case .unhover:
            guard let pointer else { return "the pointer wasn't over anything" }
            // Off the window's corner, so whatever it was over sees it leave.
            movePointer(to: NSPoint(x: -20, y: -20), in: pointer.window)
            self.pointer = nil
            await settleInput()
            return nil
        case let .press(chords, until):
            for round in 1...(until == nil ? 1 : 30) {
                for chord in chords {
                    press(chord)
                    await settleInput()
                }
                guard let (query, predicate) = until else { break }
                let found = check(query, predicate)
                if found.holds { return "\(round) times, to \(focusDescription())" }
                if round == 30 { throw StepFailure(expected: "\(query) \(predicate) within 30 presses", found: found.note, scope: query) }
            }
            return "to \(focusDescription())"
        case let .type(text):
            for character in text { press(Chord(character: character)) }
            await settleInput()
            return "to \(focusDescription())"
        case let .scroll(query, distance):
            return try await scroll(find(query), by: distance)
        case let .drag(query, distance):
            let node = try find(query)
            await drag(node, by: distance)
            await settleInput()
            return "from \(describe(node.centre)) in \(node.windowName)"
        case let .expect(query, predicate):
            let found = check(query, predicate)
            guard found.holds else { throw StepFailure(expected: "\(query) \(predicate)", found: found.note, scope: query) }
            return found.note
        case let .expectRequest(name, attempted):
            let blocked = SnapshotRun.readOnlyGitHub.blocked + ReadOnlyGit.refused + SnapshotRun.blockedLaunches
            let matching = blocked.filter { $0.contains(name) }
            guard matching.isEmpty != attempted else {
                throw StepFailure(expected: "\(attempted ? "an" : "no") attempt at \(name)", found: blocked.isEmpty ? "nothing blocked" : "blocked: \(blocked.joined(separator: "; "))")
            }
            return attempted ? "blocked: \(matching.joined(separator: "; "))" : nil
        case let .expectCopied(text):
            let copied = SnapshotRun.pasteboard.string(forType: .string)
            guard copied == text else { throw StepFailure(expected: "\"\(text)\" copied", found: copied.map { "\"\($0)\" copied" } ?? "nothing copied") }
            return nil
        case let .snap(name, query):
            let url = directory.appending(path: "\(name).png")
            try await writePNG(of: query.map(find), to: url)
            print(url.path(percentEncoded: false))
            return nil
        case let .compare(first, second, differ):
            let (a, b) = (directory.appending(path: "\(first).png"), directory.appending(path: "\(second).png"))
            guard let left = pixels(of: a), let right = pixels(of: b) else { throw StepFailure(expected: "snaps \(first) and \(second) to compare", found: "one isn't written") }
            guard (left != right) == differ else { throw StepFailure(expected: "\(first) and \(second) \(differ ? "to differ" : "to match")", found: differ ? "they're the same" : "they differ") }
            return nil
        case let .dump(query):
            if let query {
                for node in findAll(query) { print(AXTree.dump(node, limit: 400)) }
            } else {
                for window in shownWindows() { print(AXTree.dump(AXNode(window: window), limit: 400)) }
            }
            return nil
        case .dumpWindows:
            for window in NSApp.windows where window.isVisible {
                let kind = window === windows.mainWindow ? "main" : window.parent === windows.mainWindow ? "child of main" : "other"
                print("\(type(of: window)) \(kind) frame \(describe(window.frame)) alpha \(window.alphaValue) \(window.isKeyWindow ? "key " : "")\(window.isMainWindow ? "main " : "")first responder \(window.firstResponder.map { "\(type(of: $0))" } ?? "none")")
            }
            print("app active \(NSApp.isActive), key window \(NSApp.keyWindow.map { "\(type(of: $0))" } ?? "none")")
            return nil
        case let .choose(title):
            guard let menu else { throw StepFailure(expected: "a menu from a right-click", found: "none open") }
            guard let index = menu.items.firstIndex(where: { $0.title == title }) else {
                throw StepFailure(expected: "a menu item \"\(title)\"", found: "items: \(menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: ", "))")
            }
            menu.performActionForItem(at: index)
            self.menu = nil
            await settleInput()
            return nil
        }
    }

    // MARK: Opening and waiting

    private func open(_ target: OpenTarget) async throws -> String? {
        let tabs = windows.tabs
        switch target {
        case .lists:
            windows.select(nil)
        case let .listed(list, position):
            let listed = tabs.lists.pullRequests(in: list)
            guard listed.indices.contains(position - 1) else {
                throw StepFailure(expected: "a \(position)th PR in \(list.rawValue)", found: "\(listed.count) listed")
            }
            tabs.open(listed[position - 1])
        case let .link(link):
            if let task = tabs.open(link) { await task.value }
        }
        await settleInput()
        return "showing \(windows.title(of: tabs.selected))"
    }

    /// Waits until the lists have refreshed and the shown PR has its changes and conversation,
    /// or they've failed.
    private func settle(within timeout: Duration) async throws -> String? {
        let tabs = windows.tabs
        let deadline = Date.now + timeout.timeInterval
        let isSettled = {
            guard !tabs.lists.isLoading else { return false }
            guard let tab = tabs.selected.flatMap(tabs.tab(id:)) else { return tabs.selected.flatMap(tabs.item(id:))?.pending == nil }
            switch tab.phase {
            case .producing: return false
            case .ready, .failed, .noCheckout: break
            }
            guard !tab.isReplacingShownChanges, tab.isConversationSettled else { return false }
            guard tab.shownSection == .conversation, tab.conversation != nil else { return true }
            return ConversationPage.existingPage(for: tab)?.isLoaded == true
        }
        while !isSettled() {
            guard Date.now < deadline else { throw StepFailure(expected: "the app to settle within \(timeout)", found: "still loading") }
            try? await Task.sleep(for: .milliseconds(25))
        }
        await settleInput()
        return nil
    }

    /// Lets an input's effects land, then lays them out and draws them, as the screen would ask:
    /// until the main thread has handled the input and what it set off there, with nothing left
    /// to do. Work off the main thread, such as a fetch, needs `wait until`.
    private func settleInput() async {
        let deadline = ContinuousClock.now + .milliseconds(250)
        // Twice, so what the first pass queued, such as SwiftUI's updates, has run too.
        for _ in 1...2 { await mainRunLoopIdle(until: deadline) }
        for window in shownWindows() {
            window.layoutIfNeeded()
            window.displayIfNeeded()
        }
        placeChildWindows()
    }

    // MARK: Finding

    private func shownWindows() -> [NSWindow] {
        guard let main = windows.mainWindow else { return [] }
        // Popovers and sheets first, as they're in front.
        return [main].flatMap(childWindows).reversed() + [main]
    }

    private func childWindows(of window: NSWindow) -> [NSWindow] {
        ((window.childWindows ?? []) + [window.attachedSheet].compactMap { $0 }).filter(\.isVisible).flatMap { [$0] + childWindows(of: $0) }
    }

    private func findAll(_ query: Query) -> [AXNode] {
        var scopes = shownWindows().map(AXNode.init(window:))
        for (index, part) in query.parts.reversed().enumerated() {
            // The outermost part can be a window itself, such as a popover's; the rest are inside.
            let matches = scopes.flatMap { scope in ((index == 0 ? [scope] : []) + AXTree.descendants(of: scope)).filter { part.matches($0) } }
            scopes = part.pick(from: uniqued(matches))
            guard !scopes.isEmpty else { return [] }
        }
        return scopes
    }

    private func find(_ query: Query) throws -> AXNode {
        guard let node = findAll(query).first else { throw StepFailure(expected: "\(query)", found: "nothing matches", scope: query) }
        return node
    }

    private func check(_ query: Query, _ predicate: Predicate) -> (holds: Bool, note: String) {
        let nodes = findAll(query)
        if case let .count(comparison) = predicate.test {
            let holds = comparison.holds(for: nodes.count) != predicate.negated
            return (holds, "\(nodes.count) found")
        }
        guard let node = nodes.first else {
            return (predicate.test == .exists && predicate.negated, "nothing matches")
        }
        let (holds, actual) = predicate.test.evaluate(on: node, focus: focusedView(in: node.window))
        return (holds != predicate.negated, actual)
    }

    // MARK: Input

    /// Moves the pointer as the mouse would, telling each tracking area it leaves, enters and moves
    /// within, as AppKit does with the window server's mouse positions, which an off-screen window
    /// never gets. Every area counts as active, as in the key window of the active app.
    private func movePointer(to point: NSPoint, in window: NSWindow) {
        let now = trackingAreas(at: point, in: window)
        for (view, area) in hovered where !now.contains(where: { $0.area === area }) {
            guard let event = enterExit(.mouseExited, area: area, at: view.window === window ? point : NSPoint(x: -20, y: -20), in: view.window ?? window) else { continue }
            (area.owner as? NSResponder)?.mouseExited(with: event)
        }
        for (_, area) in now where !hovered.contains(where: { $0.area === area }) {
            guard let event = enterExit(.mouseEntered, area: area, at: point, in: window) else { continue }
            (area.owner as? NSResponder)?.mouseEntered(with: event)
        }
        if let moved = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) {
            for (_, area) in now where area.options.contains(.mouseMoved) {
                (area.owner as? NSResponder)?.mouseMoved(with: moved)
            }
        }
        hovered = now
        pointer = (window, point)
        Self.pointerOnScreen = window.convertPoint(toScreen: point)
    }

    /// Where a script last moved the pointer, in `window`'s coordinates, or nil if it hasn't, or
    /// this isn't a scripted run.
    static func pointerLocation(in window: NSWindow) -> NSPoint? {
        pointerOnScreen.map(window.convertPoint(fromScreen:))
    }

    /// The tracking areas of the window's shown views that `point` is inside. Tooltip areas are
    /// left out, as a tooltip is a window of its own placed by the real mouse.
    private func trackingAreas(at point: NSPoint, in window: NSWindow) -> [(view: NSView, area: NSTrackingArea)] {
        guard let frame = window.contentView?.superview, frame.bounds.contains(frame.convert(point, from: nil)) else { return [] }
        let firstResponder = window.firstResponder
        return ([frame] + descendants(of: frame)).filter { !$0.isHiddenOrHasHiddenAncestor }.flatMap { view in
            view.trackingAreas.compactMap { area -> (view: NSView, area: NSTrackingArea)? in
                guard area.options.contains(.mouseEnteredAndExited) || area.options.contains(.mouseMoved),
                      let owner = area.owner as? NSResponder, !"\(type(of: owner))".localizedCaseInsensitiveContains("tooltip"),
                      !area.options.contains(.activeWhenFirstResponder) || firstResponder === view
                else { return nil }
                let rect = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                return rect.contains(view.convert(point, from: nil)) ? (view, area) : nil
            }
        }
    }

    private func enterExit(_ type: NSEvent.EventType, area: NSTrackingArea, at point: NSPoint, in window: NSWindow) -> NSEvent? {
        // AppKit numbers an area's events by the area itself, which is how `trackingArea` finds it.
        NSEvent.enterExitEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, trackingNumber: Int(bitPattern: Unmanaged.passUnretained(area).toOpaque()), userData: nil
        )
    }

    /// Clicks the element's centre with the pointer moved there first. The click goes through the
    /// app's queue as the window server's would, except to a view that doesn't take the first click
    /// in a window that isn't key: AppKit would only make the window key, and an inactive app's
    /// window never becomes key, so the click goes to the view as AppKit sends it once key.
    private func click(_ node: AXNode, twice: Bool, modifiers: NSEvent.ModifierFlags = []) async {
        movePointer(to: node.centre, in: node.window)
        let window = node.window
        guard let frame = window.contentView?.superview, let view = frame.hitTest(frame.convert(node.centre, from: nil)) else { return }
        for count in twice ? [1, 2] : [1] {
            guard let down = mouseEvent(.leftMouseDown, at: node.centre, in: window, clickCount: count, modifiers: modifiers),
                  let up = mouseEvent(.leftMouseUp, at: node.centre, in: window, clickCount: count, modifiers: modifiers)
            else { return }
            if window.isKeyWindow && NSApp.isActive || view.acceptsFirstMouse(for: down) {
                NSApp.postEvent(down, atStart: false)
                NSApp.postEvent(up, atStart: false)
            } else {
                // Queued first, so a tracking loop the mouse-down starts finds it.
                NSApp.postEvent(up, atStart: false)
                if view.acceptsFirstResponder { window.makeFirstResponder(view) }
                view.mouseDown(with: down)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
    }


    /// Drags by `distance`, in window coordinates, so up is positive y.
    private func drag(_ node: AXNode, by distance: CGVector) async {
        movePointer(to: node.centre, in: node.window)
        let window = node.window
        let end = NSPoint(x: node.centre.x + distance.dx, y: node.centre.y + distance.dy)
        // In steps, as a hand would, so a gesture sees the drag start before it ends.
        let path = (1...Self.dragSteps).map { step in
            let part = CGFloat(step) / CGFloat(Self.dragSteps)
            return NSPoint(x: node.centre.x + distance.dx * part, y: node.centre.y + distance.dy * part)
        }
        guard let down = mouseEvent(.leftMouseDown, at: node.centre, in: window, clickCount: 1),
              let up = mouseEvent(.leftMouseUp, at: end, in: window, clickCount: 1)
        else { return }
        let drags = path.compactMap { mouseEvent(.leftMouseDragged, at: $0, in: window, clickCount: 1) }
        // Through the window, which hands each to the view the drag began in.
        window.sendEvent(down)
        for event in drags {
            try? await Task.sleep(for: .milliseconds(20))
            window.sendEvent(event)
        }
        window.sendEvent(up)
        movePointer(to: end, in: window)
    }

    private static let dragSteps = 8

    /// Asks the view under the element for its context menu, as a right-click would, without
    /// showing it: a shown menu tracks the real mouse on the user's screen until dismissed.
    private func rightClick(_ node: AXNode) throws -> String {
        movePointer(to: node.centre, in: node.window)
        guard let frame = node.window.contentView?.superview,
              let view = frame.hitTest(frame.convert(node.centre, from: nil)),
              let event = mouseEvent(.rightMouseDown, at: node.centre, in: node.window, clickCount: 1),
              let menu = sequence(first: view, next: \.superview).lazy.compactMap({ $0.menu(for: event) }).first
        else { throw StepFailure(expected: "a context menu", found: "none offered") }
        menu.update()
        self.menu = menu
        return "menu: \(menu.items.map(\.title).filter { !$0.isEmpty }.joined(separator: ", "))"
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow, clickCount: Int, modifiers: NSEvent.ModifierFlags = []) -> NSEvent? {
        let isDown = [.leftMouseDown, .leftMouseDragged, .rightMouseDown].contains(type)
        return NSEvent.mouseEvent(with: type, location: point, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: isDown ? 1 : 0)
    }

    /// Queues the key's down and up for the window that has the keyboard: an open popover's, or
    /// else the main window's.
    private func press(_ chord: Chord) {
        guard let window = keyboardWindow() else { return }
        // An active app's menus are brought up to date before a key equivalent is matched; a
        // never-activated one's aren't, so items enabled since launch would refuse their keys.
        NSApp.mainMenu.map(refresh)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: chord.modifiers, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: chord.characters, charactersIgnoringModifiers: chord.charactersIgnoringModifiers, isARepeat: false, keyCode: chord.keyCode
            ) else { continue }
            NSApp.postEvent(event, atStart: false)
        }
    }

    private func keyboardWindow() -> NSWindow? {
        // A dismissed alert can stay the key window, out of sight.
        NSApp.keyWindow.flatMap { $0.isVisible ? $0 : nil } ?? shownWindows().first { $0.canBecomeKey }
    }

    /// Scrolls whatever scrolls under the element, as a mouse wheel would, by `distance` points,
    /// down for positive.
    private func scroll(_ node: AXNode, by distance: CGFloat) async throws -> String {
        guard let content = node.window.contentView?.superview,
              let view = content.hitTest(content.convert(node.centre, from: nil)),
              let scrollView = view.enclosingScrollView ?? view as? NSScrollView
        else { throw StepFailure(expected: "something to scroll under \(node.summary)", found: "no scroll view") }
        let before = scrollView.contentView.bounds.origin
        if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: Int32(-distance.rounded()), wheel2: 0, wheel3: 0),
           let event = NSEvent(cgEvent: cg) {
            scrollView.scrollWheel(with: event)
        }
        await settleInput()
        if scrollView.contentView.bounds.origin == before, let document = scrollView.documentView {
            // AppKit doesn't always scroll an off-screen window for a wheel event; move it as it would.
            let flipped = document.isFlipped ? distance : -distance
            document.scroll(NSPoint(x: before.x, y: before.y + flipped))
            await settleInput()
            return "scrolled directly, as the wheel event moved nothing"
        }
        return "scrolled to \(describe(scrollView.contentView.bounds.origin))"
    }

    // MARK: Focus

    private func focusedView(in window: NSWindow) -> NSView? {
        guard let responder = window.firstResponder else { return nil }
        if let editor = responder as? NSTextView, editor.isFieldEditor, let field = editor.delegate as? NSView { return field }
        return responder as? NSView
    }

    private func focusDescription() -> String {
        guard let window = keyboardWindow() else { return "no window" }
        let name = window === windows.mainWindow ? "the window" : "a \(type(of: window))"
        guard let view = focusedView(in: window) else { return "\(name), nothing focused" }
        let label = view.accessibilityLabel() ?? view.accessibilityPlaceholderValue() ?? ""
        return "\(name), \(type(of: view))\(label.isEmpty ? "" : " \"\(label)\"") focused"
    }

    // MARK: Windows

    /// Moves each open popover back under what was last clicked or hovered, where it'd hang on
    /// screen.
    private func placeChildWindows() {
        guard let main = windows.mainWindow else { return }
        for child in main.childWindows ?? [] where child.isVisible {
            guard !child.frame.intersects(main.frame), let anchor else { continue }
            let x = min(max(anchor.midX - child.frame.width / 2, 0), main.frame.width - child.frame.width)
            let top = anchor.minY >= child.frame.height ? anchor.minY : anchor.maxY + child.frame.height
            child.setFrameTopLeftPoint(NSPoint(x: main.frame.minX + x, y: main.frame.minY + top))
        }
    }

    // MARK: Output

    private func writePNG(of node: AXNode?, to url: URL) async throws {
        guard let main = windows.mainWindow else { throw StepFailure(expected: "a window", found: "none") }
        // A hover popover opens after its dwell, which can be after the hover step settled.
        placeChildWindows()
        let image = await snapshot(window: main)
        guard let node else { return try pngData(of: image).write(to: url) }
        // The element as drawn over the window, from its frame relative to the main window.
        let frame = node.frame.offsetBy(dx: node.window.frame.minX - main.frame.minX, dy: node.window.frame.minY - main.frame.minY)
        guard let rep = image.representations.lazy.compactMap({ $0 as? NSBitmapImageRep }).first, let cg = rep.cgImage else {
            throw StepFailure(expected: "a snapshot to crop", found: "none drawn")
        }
        let scale = CGFloat(cg.width) / main.frame.width
        let crop = CGRect(x: frame.minX * scale, y: (main.frame.height - frame.maxY) * scale, width: frame.width * scale, height: frame.height * scale).integral
        guard let cropped = cg.cropping(to: crop) else { throw StepFailure(expected: "\(node.summary) inside the window", found: "frame \(describe(frame))") }
        let out = NSBitmapImageRep(cgImage: cropped)
        guard let data = out.representation(using: .png, properties: [:]) else { throw StepFailure(expected: "a PNG", found: "none encoded") }
        try data.write(to: url)
    }

    private func report(_ failure: StepFailure, at line: ScriptLine) async {
        print("FAIL \(line.number): \(line.text)")
        print("  expected: \(failure.expected)")
        print("  found:    \(failure.found)")
        // The part of the tree it looked in: the outermost scope that matched, or every window.
        var scope = shownWindows().map(AXNode.init(window:))
        if let query = failure.scope {
            for part in query.parts.reversed().dropLast() {
                let found = part.pick(from: scope.flatMap { AXTree.descendants(of: $0).filter(part.matches) })
                if found.isEmpty { break }
                scope = found
            }
        }
        print("  in the accessibility tree:")
        for node in scope { print(AXTree.dump(node, limit: 60, indent: "    ")) }
        let url = directory.appending(path: "failure.png")
        if (try? await writePNG(of: nil, to: url)) != nil { print(url.path(percentEncoded: false)) }
    }
}

/// Why a step failed: what it wanted, what it found, and the query whose part of the tree to show.
struct StepFailure: Error {
    var expected: String
    var found: String
    var scope: Query?
}

// MARK: - The accessibility tree

/// One element of the accessibility tree, with the window it's in.
@MainActor
struct AXNode {
    /// Messaged as Objective-C does, as many elements, SwiftUI's among them, take the
    /// accessibility methods without declaring the protocol Swift would cast to.
    let element: AnyObject
    let window: NSWindow
    let depth: Int

    init(window: NSWindow) {
        element = window
        self.window = window
        depth = 0
    }

    init(element: AnyObject, window: NSWindow, depth: Int) {
        self.element = element
        self.window = window
        self.depth = depth
    }

    var role: String { element.accessibilityRole?()?.rawValue ?? legacy("AXRole") ?? "" }
    var subrole: String { element.accessibilitySubrole?()?.rawValue ?? legacy("AXSubrole") ?? "" }
    var label: String { element.accessibilityLabel?() ?? legacy("AXDescription") ?? "" }
    var title: String { element.accessibilityTitle?() ?? legacy("AXTitle") ?? "" }
    var identifier: String { element.accessibilityIdentifier?() ?? legacy("AXIdentifier") ?? "" }
    var placeholder: String { element.accessibilityPlaceholderValue?() ?? legacy("AXPlaceholderValue") ?? "" }
    var value: String {
        // Typed, as several classes declare a method of that name.
        let read: (() -> Any?)? = element.accessibilityValue
        let direct: Any? = read?() ?? nil
        let old: AnyObject? = legacy("AXValue")
        let found: Any? = direct ?? old.map { $0 as Any }
        return switch found {
        case let text as String: text
        case let text as NSAttributedString: text.string
        case let number as NSNumber: number.stringValue
        case nil, is NSNull: ""
        case let other?: "\(other)"
        }
    }
    var isSelected: Bool { element.isAccessibilitySelected?() ?? legacy("AXSelected") ?? false }
    var isEnabled: Bool { element.isAccessibilityEnabled?() ?? legacy("AXEnabled") ?? true }
    /// In the window's coordinates.
    var frame: NSRect {
        if let frame = element.accessibilityFrame?(), frame != .zero { return window.convertFromScreen(frame) }
        // In-process, the old API answers in the screen's own coordinates, from the bottom left.
        guard let position: NSValue = legacy("AXPosition"), let size: NSValue = legacy("AXSize") else { return .zero }
        return window.convertFromScreen(NSRect(origin: position.pointValue, size: size.sizeValue))
    }
    var centre: NSPoint { NSPoint(x: frame.midX, y: frame.midY) }
    var windowName: String { depth == 0 && role == "AXWindow" ? "its window" : window.contentViewController.map { "\(type(of: $0))" } ?? "\(type(of: window))" }

    /// Whether this element has the keyboard: as accessibility says, or being the window's
    /// first responder or the field it's editing.
    func isFocused(given focused: NSView?) -> Bool {
        if element.isAccessibilityFocused?() ?? legacy("AXFocused") == true { return true }
        guard let focused else { return false }
        if let view = element as? NSView { return view === focused || focused.isDescendant(of: view) && view.accessibilityChildren()?.isEmpty != false }
        // A SwiftUI element stands over the AppKit view it wraps.
        let frame = focused.convert(focused.bounds, to: nil)
        return frame.width > 0 && self.frame.insetBy(dx: -2, dy: -2).contains(frame) && frame.width * frame.height > self.frame.width * self.frame.height * 0.5
    }

    var children: [AXNode] {
        guard role != "AXWebArea" else { return [] }
        let children = element.accessibilityChildren?() ?? nil ?? legacy("AXChildren") ?? []
        return children.compactMap { child in
            let child = child as AnyObject
            if let view = child as? NSView, view.isHiddenOrHasHiddenAncestor { return nil }
            // A child window, such as a popover, is walked as a window of its own.
            if child is NSWindow { return nil }
            return AXNode(element: child, window: window, depth: depth + 1)
        }
    }

    /// An attribute through the old API, for elements such as table rows that answer only that.
    private func legacy<Value>(_ attribute: String) -> Value? {
        let get = NSSelectorFromString("accessibilityAttributeValue:")
        guard let object = element as? NSObject, object.responds(to: get) else { return nil }
        return object.perform(get, with: attribute)?.takeUnretainedValue() as? Value
    }

    var summary: String {
        var parts = [role.replacingOccurrences(of: "AX", with: "")]
        if !subrole.isEmpty { parts[0] += "/\(subrole.replacingOccurrences(of: "AX", with: ""))" }
        for (name, text) in [("", label), ("title", title), ("value", value), ("placeholder", placeholder), ("#", identifier)] where !text.isEmpty {
            let shown = text.count > 60 ? text.prefix(57) + "…" : Substring(text)
            parts.append(name == "#" ? "#\(shown)" : name.isEmpty ? "\"\(shown)\"" : "\(name)=\"\(shown)\"")
        }
        if isSelected { parts.append("[selected]") }
        if !isEnabled { parts.append("[disabled]") }
        return parts.joined(separator: " ")
    }
}

@MainActor
enum AXTree {
    /// Every element under `node`, in reading order, depth first; at most a generous number, as
    /// a long list's rows are all in the tree.
    static func descendants(of node: AXNode) -> [AXNode] {
        var found: [AXNode] = []
        var stack = node.children.reversed() as [AXNode]
        while let next = stack.popLast(), found.count < 20_000 {
            found.append(next)
            stack.append(contentsOf: next.children.reversed())
        }
        return found
    }

    /// `node` and what's under it, an element a line indented by depth, cut off after `limit`.
    static func dump(_ node: AXNode, limit: Int, indent: String = "") -> String {
        var lines: [String] = []
        func visit(_ node: AXNode, _ level: Int) {
            guard lines.count < limit else { return }
            let frame = node.frame
            lines.append("\(indent)\(String(repeating: "  ", count: level))\(node.summary)  (\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height)))")
            for child in node.children { visit(child, level + 1) }
        }
        visit(node, 0)
        if lines.count >= limit { lines.append("\(indent)…") }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Steps

/// One line of a script, as written and as parsed.
struct ScriptLine {
    let number: Int
    let text: String
    let step: Step

    /// The steps of `script`, skipping blank lines and `#` comments; throws at the first line it
    /// can't read, naming it.
    static func parse(_ script: String) throws -> [ScriptLine] {
        var lines: [ScriptLine] = []
        for (index, raw) in script.components(separatedBy: .newlines).enumerated() {
            var tokens = try Tokens(raw)
            guard !tokens.isEmpty else { continue }
            do {
                lines.append(ScriptLine(number: index + 1, text: raw.trimmingCharacters(in: .whitespaces), step: try Step(&tokens)))
            } catch let error as ScriptError {
                throw ScriptError("line \(index + 1): \(error.message)")
            }
        }
        return lines
    }
}

enum Step {
    case open(OpenTarget)
    case pause(Duration)
    case settle(Duration)
    case waitUntil(Query, Predicate, timeout: Duration)
    case click(Query, ClickKind)
    /// Moves the pointer to the element's centre, offset in window coordinates.
    case hover(Query, CGVector)
    case unhover
    /// Presses the keys in turn; with a condition, again and again until it holds.
    case press([Chord], until: (Query, Predicate)?)
    case type(String)
    case scroll(Query, CGFloat)
    /// Drags from the middle of what the query finds, this far right, or left if negative.
    case drag(Query, CGVector)
    case expect(Query, Predicate)
    case expectRequest(String, attempted: Bool)
    case expectCopied(String)
    case snap(String, Query?)
    case compare(String, String, differ: Bool)
    case dump(Query?)
    case dumpWindows
    case choose(String)

    init(_ tokens: inout Tokens) throws {
        let verb = try tokens.word()
        switch verb {
        case "open":
            let target = try tokens.word()
            if target == "lists" {
                self = .open(.lists)
            } else if let list = ["mine": PullRequestList.mine, "to-review": .toReview][target] {
                self = .open(.listed(list, try tokens.number()))
            } else if let link = PullRequestLink(shorthand: target) {
                self = .open(.link(link))
            } else {
                throw ScriptError("open takes lists, mine <n>, to-review <n> or owner/repo#<n>, not \(target)")
            }
        case "wait":
            if tokens.take("settled") {
                self = .settle(try tokens.timeout(default: .seconds(30)))
            } else if tokens.take("until") {
                let query = try Query(&tokens)
                let predicate = try Predicate(&tokens)
                self = .waitUntil(query, predicate, timeout: try tokens.timeout(default: .seconds(10)))
            } else {
                self = .pause(try tokens.duration())
            }
        case "click": self = .click(try Query(&tokens), .single)
        case "double-click": self = .click(try Query(&tokens), .double)
        case "shift-click": self = .click(try Query(&tokens), .shift)
        case "right-click": self = .click(try Query(&tokens), .right)
        case "hover":
            let query = try Query(&tokens)
            self = .hover(query, tokens.isEmpty ? CGVector() : try Self.vector(&tokens, step: "hover"))
        case "unhover": self = .unhover
        case "press":
            var chords: [Chord] = []
            while !tokens.isEmpty, tokens.peekWord() != "until" { chords.append(try Chord(try tokens.word())) }
            guard !chords.isEmpty else { throw ScriptError("press needs a key, such as down or cmd+f") }
            self = .press(chords, until: tokens.take("until") ? (try Query(&tokens), try Predicate(&tokens)) : nil)
        case "type": self = .type(try tokens.string())
        case "scroll":
            let query = try Query(&tokens)
            let direction = try tokens.word()
            guard ["up", "down"].contains(direction) else { throw ScriptError("scroll goes up or down, not \(direction)") }
            let distance = CGFloat(try tokens.number())
            self = .scroll(query, direction == "down" ? distance : -distance)
        case "drag":
            let query = try Query(&tokens)
            self = .drag(query, try Self.vector(&tokens, step: "drag"))
        case "expect": self = .expect(try Query(&tokens), try Predicate(&tokens))
        case "expect-request": self = .expectRequest(try tokens.word(), attempted: true)
        case "expect-no-request": self = .expectRequest(try tokens.word(), attempted: false)
        case "expect-copied": self = .expectCopied(try tokens.string())
        case "snap":
            let name = try tokens.word()
            self = .snap(name, tokens.isEmpty ? nil : try Query(&tokens))
        case "expect-different": self = .compare(try tokens.word(), try tokens.word(), differ: true)
        case "expect-same": self = .compare(try tokens.word(), try tokens.word(), differ: false)
        case "dump": self = tokens.take("windows") ? .dumpWindows : .dump(tokens.isEmpty ? nil : try Query(&tokens))
        case "choose": self = .choose(try tokens.string())
        default: throw ScriptError("no step \(verb)")
        }
        guard tokens.isEmpty else { throw ScriptError("didn't expect \(tokens.rest)") }
    }


    /// `left|right|up|down <points>`, as a vector in window coordinates, where up is positive y.
    private static func vector(_ tokens: inout Tokens, step: String) throws -> CGVector {
        let direction = try tokens.word()
        let distance = CGFloat(try tokens.number())
        switch direction {
        case "left": return CGVector(dx: -distance, dy: 0)
        case "right": return CGVector(dx: distance, dy: 0)
        case "up": return CGVector(dx: 0, dy: distance)
        case "down": return CGVector(dx: 0, dy: -distance)
        default: throw ScriptError("\(step) goes left, right, up or down, not \(direction)")
        }
    }
}

enum OpenTarget {
    case lists
    /// The nth PR of a list, counting from 1.
    case listed(PullRequestList, Int)
    case link(PullRequestLink)
}

enum ClickKind {
    case single, double, right, shift
}

/// What to find: `[role] ["text" | ~"text"] [#identifier] [N | last]`, optionally `in` another
/// such part that it must be inside. Text matches the label, title, value or identifier, whole
/// or (with `~`) in part, ignoring case. N picks the Nth match, counting from 1.
struct Query: CustomStringConvertible {
    /// Innermost first.
    var parts: [Part]
    let description: String

    init(_ tokens: inout Tokens) throws {
        let start = tokens.position
        parts = [try Part(&tokens)]
        while tokens.take("in") { parts.append(try Part(&tokens)) }
        description = tokens.text(from: start)
    }

    struct Part {
        var roles: [String] = []
        var texts: [(String, exact: Bool)] = []
        var identifier: String?
        var index: Int?
        var isLast = false
        var mustBeSelected = false

        init(_ tokens: inout Tokens) throws {
            if let word = tokens.peekWord(), let roles = roleNames[word] ?? (word.hasPrefix("AX") ? [word] : nil) {
                tokens.advance()
                self.roles = roles
            }
            while let next = tokens.peek() {
                switch next {
                case let .string(text, exact):
                    texts.append((text, exact))
                case let .word(word) where word.hasPrefix("#") && word.count > 1:
                    identifier = String(word.dropFirst())
                case let .word(word) where Int(word) != nil && index == nil:
                    index = Int(word)
                case .word("last"):
                    isLast = true
                case .word("selected"):
                    mustBeSelected = true
                default:
                    guard !roles.isEmpty || !texts.isEmpty || identifier != nil else { throw ScriptError("expected something to find at \(tokens.rest)") }
                    return
                }
                tokens.advance()
            }
            guard !roles.isEmpty || !texts.isEmpty || identifier != nil else { throw ScriptError("expected something to find") }
        }

        @MainActor
        func matches(_ node: AXNode) -> Bool {
            if !roles.isEmpty, !roles.contains(node.role), !roles.contains(node.subrole) { return false }
            if let identifier, node.identifier != identifier { return false }
            if mustBeSelected, !node.isSelected { return false }
            let fields = [node.label, node.title, node.value, node.placeholder, node.identifier]
            return texts.allSatisfy { text, exact in
                fields.contains { exact ? $0 == text : $0.localizedCaseInsensitiveContains(text) }
            }
        }

        /// The matches it names: the Nth, the last, or all of them.
        @MainActor
        func pick(from nodes: [AXNode]) -> [AXNode] {
            if isLast { return nodes.last.map { [$0] } ?? [] }
            guard let index else { return nodes }
            return nodes.indices.contains(index - 1) ? [nodes[index - 1]] : []
        }
    }
}

/// What a query's match should be: `exists` (the default), `missing`, `is [not] selected |
/// focused | enabled | disabled`, `has [no] value | title | label "text" | ~"text"`, or
/// `count N`, `count >N`, `count <N` over every match.
struct Predicate: CustomStringConvertible {
    var test: Test
    var negated = false

    enum Test: Equatable {
        case exists, selected, focused, enabled
        case value(String, exact: Bool), title(String, exact: Bool), label(String, exact: Bool)
        case count(Comparison)

        @MainActor
        func evaluate(on node: AXNode, focus: NSView?) -> (Bool, String) {
            switch self {
            case .exists: (true, node.summary)
            case .selected: (node.isSelected, node.summary)
            case .focused: (node.isFocused(given: focus), "\(node.summary), focus on \(focus.map { "\(type(of: $0))" } ?? "nothing")")
            case .enabled: (node.isEnabled, node.summary)
            case let .value(text, exact): (Self.matches(node.value, text, exact), "value \"\(node.value)\"")
            case let .title(text, exact): (Self.matches(node.title, text, exact), "title \"\(node.title)\"")
            case let .label(text, exact): (Self.matches(node.label, text, exact), "label \"\(node.label)\"")
            case .count: (false, "")
            }
        }

        private static func matches(_ actual: String, _ text: String, _ exact: Bool) -> Bool {
            exact ? actual == text : actual.localizedCaseInsensitiveContains(text)
        }
    }

    enum Comparison: Equatable {
        case equal(Int), more(Int), fewer(Int)

        func holds(for count: Int) -> Bool {
            switch self {
            case let .equal(n): count == n
            case let .more(n): count > n
            case let .fewer(n): count < n
            }
        }
    }

    init(_ tokens: inout Tokens) throws {
        guard let word = tokens.peekWord(), word != "timeout" else {
            test = .exists
            return
        }
        tokens.advance()
        switch word {
        case "exists": test = .exists
        case "missing":
            test = .exists
            negated = true
        case "is":
            negated = tokens.take("not")
            switch try tokens.word() {
            case "selected": test = .selected
            case "focused": test = .focused
            case "enabled": test = .enabled
            case "disabled":
                test = .enabled
                negated.toggle()
            case let other: throw ScriptError("is takes selected, focused, enabled or disabled, not \(other)")
            }
        case "has":
            negated = tokens.take("no")
            let field = try tokens.word()
            guard case let .string(text, exact)? = tokens.peek() else { throw ScriptError("has \(field) needs a quoted text") }
            tokens.advance()
            switch field {
            case "value": test = .value(text, exact: exact)
            case "title": test = .title(text, exact: exact)
            case "label": test = .label(text, exact: exact)
            default: throw ScriptError("has takes value, title or label, not \(field)")
            }
        case "count":
            let spec = try tokens.word()
            let number = Int(spec.drop { $0 == ">" || $0 == "<" })
            guard let number else { throw ScriptError("count takes N, >N or <N, not \(spec)") }
            test = .count(spec.hasPrefix(">") ? .more(number) : spec.hasPrefix("<") ? .fewer(number) : .equal(number))
        default:
            throw ScriptError("expected exists, missing, is, has or count, not \(word)")
        }
    }

    var description: String {
        let not = negated ? "not " : ""
        return switch test {
        case .exists: negated ? "to be missing" : "to exist"
        case .selected: "to be \(not)selected"
        case .focused: "to be \(not)focused"
        case .enabled: negated ? "to be disabled" : "to be enabled"
        case let .value(text, exact): "to \(negated ? "not " : "")have value \(exact ? "" : "~")\"\(text)\""
        case let .title(text, exact): "to \(negated ? "not " : "")have title \(exact ? "" : "~")\"\(text)\""
        case let .label(text, exact): "to \(negated ? "not " : "")have label \(exact ? "" : "~")\"\(text)\""
        case let .count(comparison): "to number \(comparison)"
        }
    }
}

/// A key and its modifiers, as `cmd+shift+p`, `down` or `a`.
struct Chord {
    let characters: String
    let charactersIgnoringModifiers: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    init(_ spec: String) throws {
        var parts = spec.lowercased().split(separator: "+").map(String.init)
        // `cmd++` names the plus key.
        if spec.hasSuffix("++") { parts.append("+") }
        guard let key = parts.popLast() else { throw ScriptError("no key in \(spec)") }
        var modifiers: NSEvent.ModifierFlags = []
        for name in parts {
            guard let modifier = modifierNames[name] else { throw ScriptError("no modifier \(name) in \(spec)") }
            modifiers.insert(modifier)
        }
        if let special = specialKeys[key] {
            let character = String(UnicodeScalar(special.character).map(Character.init) ?? " ")
            self.init(characters: character, ignoring: character, keyCode: special.code, modifiers: modifiers.union(special.flags))
        } else if key.count == 1, let character = key.first, let code = keyCodes[character] {
            // Shift types a capital, or the symbol over the key: `shift+/` is `?`.
            let shifted = shiftedKeys.first { $0.value.0 == character }?.key
            let typed = modifiers.contains(.shift) ? shifted.map(String.init) ?? String(character).uppercased() : String(character)
            // Control turns a letter into its control character, as the keyboard does.
            let controlled = modifiers.contains(.control) ? character.asciiValue.flatMap { $0 >= 97 && $0 <= 122 ? String(UnicodeScalar($0 - 96)) : nil } : nil
            self.init(characters: controlled ?? typed, ignoring: String(character), keyCode: code, modifiers: modifiers)
        } else {
            throw ScriptError("no key \(key) in \(spec)")
        }
    }

    /// The key that types `character`, shifted for a capital or a symbol over a digit.
    init(character: Character) {
        let lower = Character(character.lowercased())
        if let code = keyCodes[lower] {
            self.init(characters: String(character), ignoring: String(lower), keyCode: code, modifiers: lower == character ? [] : .shift)
        } else if let (base, code) = shiftedKeys[character] {
            self.init(characters: String(character), ignoring: String(base), keyCode: code, modifiers: .shift)
        } else {
            self.init(characters: String(character), ignoring: String(character), keyCode: 0, modifiers: [])
        }
    }

    private init(characters: String, ignoring: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.characters = characters
        charactersIgnoringModifiers = ignoring
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

struct ScriptError: Error, CustomStringConvertible {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var description: String { message }
}

/// A line's words and quoted texts, in order, read from the front.
struct Tokens {
    enum Token: Equatable {
        case word(String)
        /// Quoted; `~"…"` matches in part rather than whole.
        case string(String, exact: Bool)
    }

    private var tokens: [(Token, String)]
    private(set) var position = 0

    init(_ line: String) throws {
        tokens = []
        var characters = line[...]
        while let first = characters.first {
            if first.isWhitespace {
                characters = characters.dropFirst()
            } else if first == "#" && (characters.dropFirst().first?.isWhitespace ?? true) || first == "#" && tokens.isEmpty {
                // A comment: `#` alone or starting the line; `#name` is an identifier.
                break
            } else if first == "\"" || first == "~" && characters.dropFirst().first == "\"" {
                let exact = first == "\""
                var rest = characters.dropFirst(exact ? 1 : 2)
                var text = ""
                while let next = rest.first, next != "\"" {
                    if next == "\\", let escaped = rest.dropFirst().first {
                        text.append(escaped == "n" ? "\n" : escaped)
                        rest = rest.dropFirst(2)
                    } else {
                        text.append(next)
                        rest = rest.dropFirst()
                    }
                }
                guard rest.first == "\"" else { throw ScriptError("unclosed quote in \(line)") }
                let consumed = characters[characters.startIndex..<rest.index(after: rest.startIndex)]
                tokens.append((.string(text, exact: exact), String(consumed)))
                characters = rest.dropFirst()
            } else {
                let word = characters.prefix { !$0.isWhitespace }
                tokens.append((.word(String(word)), String(word)))
                characters = characters.dropFirst(word.count)
            }
        }
    }

    var isEmpty: Bool { position >= tokens.count }
    var rest: String { tokens[position...].map(\.1).joined(separator: " ") }

    func peek() -> Token? { isEmpty ? nil : tokens[position].0 }

    func peekWord() -> String? {
        if case let .word(word)? = peek() { return word }
        return nil
    }

    func text(from start: Int) -> String { tokens[start..<position].map(\.1).joined(separator: " ") }

    mutating func advance() { position += 1 }

    mutating func take(_ word: String) -> Bool {
        guard peekWord() == word else { return false }
        advance()
        return true
    }

    mutating func word() throws -> String {
        guard let word = peekWord() else { throw ScriptError(isEmpty ? "the line ends too soon" : "expected a word at \(rest)") }
        advance()
        return word
    }

    mutating func string() throws -> String {
        guard case let .string(text, _)? = peek() else { throw ScriptError("expected a quoted text at \(isEmpty ? "the end" : rest)") }
        advance()
        return text
    }

    mutating func number() throws -> Int {
        let word = try word()
        guard let number = Int(word) else { throw ScriptError("expected a number, not \(word)") }
        return number
    }

    /// `500ms`, `2s` or `1.5s`.
    mutating func duration() throws -> Duration {
        let word = try word()
        if word.hasSuffix("ms"), let ms = Int(word.dropLast(2)) { return .milliseconds(ms) }
        if word.hasSuffix("s"), let seconds = Double(word.dropLast()) { return .milliseconds(Int(seconds * 1000)) }
        throw ScriptError("expected a duration such as 500ms or 2s, not \(word)")
    }

    /// `timeout <duration>` if it's next, or `default`.
    mutating func timeout(default fallback: Duration) throws -> Duration {
        take("timeout") ? try duration() : fallback
    }
}

// MARK: - Helpers

private extension PullRequestLink {
    /// `owner/repo#123`.
    init?(shorthand: String) {
        let parts = shorthand.split(separator: "#")
        guard parts.count == 2, parts[0].split(separator: "/").count == 2, let number = Int(parts[1]) else { return nil }
        self.init(repository: String(parts[0]), number: number)
    }
}

@MainActor
private func uniqued(_ nodes: [AXNode]) -> [AXNode] {
    var seen: Set<ObjectIdentifier> = []
    return nodes.filter { seen.insert(ObjectIdentifier($0.element)).inserted }
}

private func describe(_ point: NSPoint) -> String { "(\(Int(point.x)), \(Int(point.y)))" }

private func describe(_ rect: NSRect) -> String { "(\(Int(rect.minX)), \(Int(rect.minY)) \(Int(rect.width))x\(Int(rect.height)))" }

@MainActor
private func pngData(of image: NSImage) throws -> Data {
    guard let rep = image.representations.lazy.compactMap({ $0 as? NSBitmapImageRep }).first,
          let data = rep.representation(using: .png, properties: [:])
    else { throw CocoaError(.fileWriteUnknown) }
    return data
}

/// A PNG's pixels, to tell whether two snaps differ by what they show rather than how they're
/// encoded.
private func pixels(of url: URL) -> Data? {
    guard let rep = (try? Data(contentsOf: url)).flatMap(NSBitmapImageRep.init(data:)), let data = rep.bitmapData else { return nil }
    return Data(bytes: data, count: rep.bytesPerRow * rep.pixelsHigh)
}

private extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return TimeInterval(seconds) + TimeInterval(attoseconds) / 1e18
    }
}

/// The friendly role names a query can start with, each the accessibility roles (or subroles)
/// it stands for.
private let roleNames: [String: [String]] = [
    "button": ["AXButton"], "row": ["AXRow"], "cell": ["AXCell"], "text": ["AXStaticText"],
    "field": ["AXTextField", "AXSearchField"], "search": ["AXSearchField"], "textarea": ["AXTextArea"], "checkbox": ["AXCheckBox"],
    "radio": ["AXRadioButton"], "list": ["AXList", "AXOutline", "AXTable"], "group": ["AXGroup"],
    "image": ["AXImage"], "link": ["AXLink"], "menuitem": ["AXMenuItem"], "popup": ["AXPopUpButton"],
    "menubutton": ["AXMenuButton"], "scroll": ["AXScrollArea"], "toolbar": ["AXToolbar"],
    "popover": ["AXPopover"], "web": ["AXWebArea"], "disclosure": ["AXDisclosureTriangle"],
    "tabs": ["AXTabGroup"], "segments": ["AXRadioGroup"], "window": ["AXWindow"], "any": [],
]

private let modifierNames: [String: NSEvent.ModifierFlags] = [
    "cmd": .command, "command": .command, "shift": .shift, "opt": .option, "option": .option, "alt": .option,
    "ctrl": .control, "control": .control, "fn": .function,
]

/// Keys that type no character of their own: AppKit's function-key character, key code and the
/// flags the keyboard adds.
private let specialKeys: [String: (character: UInt32, code: UInt16, flags: NSEvent.ModifierFlags)] = {
    let arrows: NSEvent.ModifierFlags = [.numericPad, .function]
    var keys: [String: (character: UInt32, code: UInt16, flags: NSEvent.ModifierFlags)] = [
        "up": (UInt32(NSUpArrowFunctionKey), 126, arrows), "down": (UInt32(NSDownArrowFunctionKey), 125, arrows),
        "left": (UInt32(NSLeftArrowFunctionKey), 123, arrows), "right": (UInt32(NSRightArrowFunctionKey), 124, arrows),
        "return": (13, 36, []), "enter": (3, 76, .numericPad), "tab": (9, 48, []), "space": (32, 49, []),
        "esc": (27, 53, []), "escape": (27, 53, []), "delete": (127, 51, []), "backspace": (127, 51, []),
        "forward-delete": (UInt32(NSDeleteFunctionKey), 117, .function), "home": (UInt32(NSHomeFunctionKey), 115, .function),
        "end": (UInt32(NSEndFunctionKey), 119, .function), "pageup": (UInt32(NSPageUpFunctionKey), 116, .function),
        "pagedown": (UInt32(NSPageDownFunctionKey), 121, .function),
    ]
    let functionCodes: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
    for (index, code) in functionCodes.enumerated() {
        keys["f\(index + 1)"] = (UInt32(NSF1FunctionKey + index), code, .function)
    }
    return keys
}()

/// The US keyboard's key codes for the characters it types unshifted.
private let keyCodes: [Character: UInt16] = [
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12,
    "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23,
    "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34,
    "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46,
    ".": 47, "`": 50, " ": 49,
]

/// Characters typed with shift, by the unshifted character and key code of their key.
private let shiftedKeys: [Character: (Character, UInt16)] = {
    let pairs: [(Character, Character)] = [
        ("!", "1"), ("@", "2"), ("#", "3"), ("$", "4"), ("%", "5"), ("^", "6"), ("&", "7"), ("*", "8"), ("(", "9"), (")", "0"),
        ("_", "-"), ("+", "="), ("{", "["), ("}", "]"), ("|", "\\"), (":", ";"), ("\"", "'"), ("<", ","), (">", "."), ("?", "/"), ("~", "`"),
    ]
    return Dictionary(uniqueKeysWithValues: pairs.compactMap { shifted, base in keyCodes[base].map { (shifted, (base, $0)) } })
}()

/// Returns once the main run loop has handled everything queued for it, and Core Animation has
/// committed what that changed, and it's about to sleep; or at `deadline`, should it never be.
@MainActor
private func mainRunLoopIdle(until deadline: ContinuousClock.Instant) async {
    guard ContinuousClock.now < deadline else { return }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let resume = OneShot(continuation)
        // Ordered last, after Core Animation's commit at the same point.
        let observer = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, false, CFIndex.max) { _, _ in
            resume.fire()
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        Task { @MainActor in
            try? await Task.sleep(until: deadline)
            CFRunLoopObserverInvalidate(observer)
            resume.fire()
        }
    }
}

/// Resumes a continuation the first time it's fired, from whichever of its callers comes first.
private final class OneShot: Sendable {
    private let continuation = OSAllocatedUnfairLock<CheckedContinuation<Void, Never>?>(initialState: nil)

    init(_ continuation: CheckedContinuation<Void, Never>) {
        self.continuation.withLock { $0 = continuation }
    }

    func fire() {
        continuation.withLock { pending in
            pending?.resume()
            pending = nil
        }
    }
}

/// Brings `menu` and its submenus up to date, as AppKit does before it matches a key equivalent.
@MainActor
private func refresh(_ menu: NSMenu) {
    menu.delegate?.menuNeedsUpdate?(menu)
    menu.update()
    for item in menu.items { item.submenu.map(refresh) }
}
