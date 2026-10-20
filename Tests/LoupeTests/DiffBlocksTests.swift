import AppKit
import LoupeCore
import Testing

@MainActor
struct DiffBlocksTests {
    @Test func blocksGetARowOfTheirHeightUnderTheirLineAndCopiesLeaveThemOut() throws {
        let goMod = try fixtureFile("go.mod")
        let blocks = [
            DiffBlock(id: "added", placement: .after(side: .right, line: 10), height: 50),
            DiffBlock(id: "deleted", placement: .after(side: .left, line: 10), height: 30),
            DiffBlock(id: "unchanged", placement: .after(side: .right, line: 7), height: 30),
            DiffBlock(id: "missing", placement: .after(side: .right, line: 9_999), height: 30),
            DiffBlock(id: "end", placement: .end, height: 30),
        ]
        let rendered = RenderedDiff(file: goMod, blocks: blocks)
        let text = rendered.text.string as NSString

        func row(containing needle: String) -> Int? {
            rendered.row(at: text.range(of: needle).location)
        }
        #expect(rendered.blockRows["unchanged"] == row(containing: "require (").map { $0 + 1 })
        #expect(rendered.blockRows["deleted"] == row(containing: "aws-sdk-go v1.49.23").map { $0 + 1 })
        #expect(rendered.blockRows["added"] == row(containing: "transfermanager v0.4.14").map { $0 + 1 })
        // A line the diff doesn't have puts its block at the end, in the order given.
        #expect(rendered.blockRows["missing"] == rendered.rowStarts.count - 2)
        #expect(rendered.blockRows["end"] == rendered.rowStarts.count - 1)
        #expect(rendered.blockRows.values.allSatisfy { rendered.rowAnchors[$0] == nil })
        // Pairs of modified lines are still compared word by word with a block between them.
        let changed = text.range(of: "4d2e42eff668")
        #expect(rendered.text.attribute(.diffEmphasis, at: changed.location, effectiveRange: nil) != nil)

        let view = DiffTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.show(rendered)
        let layoutManager = try #require(view.layoutManager)
        layoutManager.ensureLayout(for: try #require(view.textContainer))
        func fragment(_ id: String) throws -> NSRect {
            let range = try #require(rendered.range(ofBlock: id))
            return layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: range.location), effectiveRange: nil)
        }
        #expect(try fragment("added").height == 50)

        // A view laid over a block sits on its row, and follows it when one above grows.
        let card = NSView()
        view.setBlockViews(["added": card])
        #expect(card.frame.minY == (try fragment("added").minY) + view.textContainerOrigin.y)
        #expect(card.frame.height == 50)
        view.setHeight(80, ofBlock: "deleted")
        layoutManager.ensureLayout(for: try #require(view.textContainer))
        #expect(try fragment("deleted").height == 80)
        #expect(card.frame.minY == (try fragment("added").minY) + view.textContainerOrigin.y)
        #expect(card.superview === view)
        view.setBlockViews([:])
        #expect(card.superview == nil)

        let start = text.range(of: "@@ -7,7").location
        let end = NSMaxRange(text.lineRange(for: NSRange(location: text.range(of: "transfermanager").location, length: 0)))
        view.setSelectedRange(NSRange(location: start, length: end - start))
        let board = NSPasteboard(name: NSPasteboard.Name("LoupeTests-\(UUID())"))
        defer { board.releaseGlobally() }
        board.clearContents()
        #expect(view.writeSelection(to: board, type: .string))
        #expect(board.string(forType: .string) == """
        @@ -7,7 +7,7 @@ retract v0.657.0
        require (
        \tgithub.com/DATA-DOG/go-sqlmock v1.5.2
        \tgithub.com/actgardner/gogen-avro/v7 v7.0.0
        \tgithub.com/aws/aws-sdk-go v1.49.23
        \tgithub.com/aws/aws-sdk-go-v2/feature/s3/transfermanager v0.4.14

        """)
    }

    @Test func hoveringARowThatTakesACommentShowsAPlusThatStartsOne() throws {
        let goMod = try fixtureFile("go.mod")
        let view = DiffTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.show(RenderedDiff(file: goMod))
        view.layoutManager?.ensureLayout(for: try #require(view.textContainer))
        let added = DiffAnchor(path: "go.mod", side: .right, line: 10)
        view.commentableAnchors = [added]
        var asked: [DiffAnchor] = []
        view.onComment = { anchor, start in asked.append(anchor); #expect(start == nil) }

        try hover(onRowContaining: "transfermanager", in: view)
        #expect(!view.commentButton.isHidden)
        let row = try #require(view.rendered?.row(at: (view.string as NSString).range(of: "transfermanager").location))
        #expect(view.commentButton.frame.midY > (try top(ofRow: row, in: view)))
        view.commentButton.performClick(nil)
        #expect(asked == [added])

        try hover(onRowContaining: "require (", in: view)
        #expect(view.commentButton.isHidden, "a row it can't take a comment on")
        try hover(onRowContaining: "@@ -7,7", in: view)
        #expect(view.commentButton.isHidden, "a hunk header")
        view.commentableAnchors = nil
        try hover(onRowContaining: "transfermanager", in: view)
        #expect(view.commentButton.isHidden, "nothing takes comments")
    }

    @Test func middleClickingARowThatTakesACommentStartsOneThere() throws {
        let goMod = try fixtureFile("go.mod")
        let view = DiffTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.show(RenderedDiff(file: goMod))
        view.layoutManager?.ensureLayout(for: try #require(view.textContainer))
        let added = DiffAnchor(path: "go.mod", side: .right, line: 10)
        view.commentableAnchors = [added]
        var asked: [DiffAnchor] = []
        view.onComment = { anchor, start in asked.append(anchor); #expect(start == nil) }
        let text = view.string as NSString
        let code = text.range(of: "transfermanager")
        let row = try #require(view.rendered?.row(at: code.location))
        let gutter = NSRange(location: try #require(view.rendered).rowStarts[row], length: 1)

        try middleClick(on: code, in: view)
        #expect(asked == [added], "its code")
        try middleClick(on: gutter, in: view)
        #expect(asked == [added, added], "its gutter")

        asked = []
        try middleClick(on: text.range(of: "require ("), in: view)
        #expect(asked.isEmpty, "a row it can't take a comment on")
        try middleClick(on: text.range(of: "@@ -7,7"), in: view)
        #expect(asked.isEmpty, "a hunk header")
    }

    @Test func thePlusOnASelectionOfSeveralRowsStartsACommentOnThemAll() throws {
        let goMod = try fixtureFile("go.mod")
        let view = DiffTextView.make()
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        view.show(RenderedDiff(file: goMod))
        view.layoutManager?.ensureLayout(for: try #require(view.textContainer))
        let deleted = DiffAnchor(path: "go.mod", side: .left, line: 10)
        let added = DiffAnchor(path: "go.mod", side: .right, line: 10)
        let unchanged = DiffAnchor(path: "go.mod", side: .right, line: 11)
        view.commentableAnchors = [DiffAnchor(path: "go.mod", side: .right, line: 9), deleted, added, unchanged]
        var asked: [[DiffAnchor?]] = []
        view.onComment = { anchor, start in asked.append([start, anchor]) }
        let text = view.string as NSString
        // From part way into the deleted row to part way into the unchanged one, as a drag.
        let from = text.range(of: "aws-sdk-go v1.49.23").location
        view.setSelectedRange(NSRange(location: from, length: text.range(of: "bugsnag").location - from))

        try hover(onRowContaining: "transfermanager", in: view)
        #expect(view.commentButton.toolTip?.contains("lines 10–11") == true)
        view.commentButton.performClick(nil)
        #expect(asked == [[deleted, unchanged]], "the selection's first and last rows, whichever is clicked")
        try middleClick(on: text.range(of: "bugsnag"), in: view)
        #expect(asked.last == [deleted, unchanged], "a middle click in the selection does the same")

        try middleClick(on: text.range(of: "gogen-avro"), in: view)
        #expect(asked.last == [nil, DiffAnchor(path: "go.mod", side: .right, line: 9)], "a row outside the selection takes a comment of its own")
        view.setSelectedRange(NSRange(location: from, length: 3))
        try middleClick(on: text.range(of: "aws-sdk-go v1.49.23"), in: view)
        #expect(asked.last == [nil, deleted], "a selection within one row")

    }

    @Test func doubleClickingARowThatTakesACommentSelectsAWord() throws {
        let goMod = try fixtureFile("go.mod")
        let view = DiffTextView.make()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        window.contentView = view
        view.show(RenderedDiff(file: goMod))
        view.layoutManager?.ensureLayout(for: try #require(view.textContainer))
        view.commentableAnchors = [DiffAnchor(path: "go.mod", side: .right, line: 10)]
        var asked: [DiffAnchor] = []
        view.onComment = { anchor, start in asked.append(anchor); #expect(start == nil) }
        let word = (view.string as NSString).range(of: "transfermanager")

        try doubleClick(on: word, in: view)
        #expect(asked.isEmpty)
        #expect(view.selectedRange() == word)
    }
}

/// Sends the mouse moving over the middle of the text on a row, as hovering does.
@MainActor
private func hover(onRowContaining needle: String, in view: DiffTextView) throws {
    let layoutManager = try #require(view.layoutManager)
    let container = try #require(view.textContainer)
    let found = (view.string as NSString).range(of: needle)
    let bounds = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: found, actualCharacterRange: nil), in: container)
    let point = view.convert(NSPoint(x: bounds.midX + view.textContainerOrigin.x, y: bounds.midY + view.textContainerOrigin.y), to: nil)
    let event = try #require(NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 0, pressure: 0))
    view.mouseMoved(with: event)
}

@MainActor
private func top(ofRow row: Int, in view: DiffTextView) throws -> CGFloat {
    let layoutManager = try #require(view.layoutManager)
    let start = try #require(view.rendered).rowStarts[row]
    return layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: start), effectiveRange: nil).minY + view.textContainerOrigin.y
}

/// Sends a middle mouse down over the middle of a range of the text, as a middle click arrives.
@MainActor
private func middleClick(on range: NSRange, in view: DiffTextView) throws {
    let point = try point(over: range, in: view)
    // AppKit's factory can't name the button, so the event is given the middle one through Quartz.
    let made = try #require(NSEvent.mouseEvent(with: .otherMouseDown, location: point, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)?.cgEvent)
    made.setIntegerValueField(.mouseEventButtonNumber, value: Int64(CGMouseButton.center.rawValue))
    let event = try #require(NSEvent(cgEvent: made))
    #expect(event.buttonNumber == 2 && event.locationInWindow == point)
    view.otherMouseDown(with: event)
}

/// Clicks twice over the middle of a range of the text, as a double-click arrives. Each mouse-up
/// is posted from inside the text view's selection tracking, which waits for it; posting wakes the
/// running loop, and before tracking that's the one the test runner exits after.
@MainActor
private func doubleClick(on range: NSRange, in view: DiffTextView) throws {
    let point = try point(over: range, in: view)
    let windowNumber = try #require(view.window).windowNumber
    for clickCount in 1...2 {
        let up = try #require(NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 0))
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: clickCount, pressure: 1))
        nonisolated(unsafe) let posted = up
        RunLoop.main.perform(inModes: [.eventTracking]) { MainActor.assumeIsolated { NSApplication.shared.postEvent(posted, atStart: false) } }
        view.mouseDown(with: down)
    }
}

/// The middle of a range of the text, in window coordinates.
@MainActor
private func point(over range: NSRange, in view: DiffTextView) throws -> NSPoint {
    let layoutManager = try #require(view.layoutManager)
    let container = try #require(view.textContainer)
    let bounds = layoutManager.boundingRect(forGlyphRange: layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
    return view.convert(NSPoint(x: bounds.midX + view.textContainerOrigin.x, y: bounds.midY + view.textContainerOrigin.y), to: nil)
}
