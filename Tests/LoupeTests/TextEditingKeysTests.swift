import AppKit
import LoupeCore
import Testing

/// The keys are sent through the app as AppKit delivers them, its menus included, to a window
/// that's never shown.
@MainActor
@Suite(.serialized)
struct TextEditingKeysTests {
    @Test func commandDownGoesToTheEndOfTheTextRatherThanToTheMenu() throws {
        let app = try TestApp()
        let text = app.focusText("one\ntwo\nthree", editable: true)

        app.press(downArrow, modifiers: .command)

        #expect(text.selectedRange() == NSRange(location: 13, length: 0))
        #expect(app.menuPresses == 0)
    }

    @Test func commandDownGoesToTheMenuWhenTheFocusIsntInText() throws {
        let app = try TestApp()
        _ = app.focusText("one\ntwo\nthree", editable: false)

        app.press(downArrow, modifiers: .command)

        #expect(app.menuPresses == 1)
    }

    @Test func selectingAndDeletingKeysEditTheText() throws {
        let app = try TestApp()
        let text = app.focusText("one two\nthree", editable: true)
        text.setSelectedRange(NSRange(location: 13, length: 0))

        app.press(upArrow, modifiers: [.command, .shift])
        #expect(text.selectedRange() == NSRange(location: 0, length: 13))

        text.setSelectedRange(NSRange(location: 7, length: 0))
        app.press(backspace, modifiers: .option)
        #expect(text.string == "one \nthree")

        app.press("e", modifiers: .control)
        #expect(text.selectedRange() == NSRange(location: 4, length: 0))
        #expect(app.menuPresses == 0)
    }

    @Test func otherKeysStillReachTheMenus() throws {
        let app = try TestApp()
        _ = app.focusText("one", editable: true)

        app.press("]", modifiers: [.command, .shift])

        #expect(app.menuPresses == 1)
    }
}

/// The app with a menu taking ⌘↓ and ⌘⇧], as Loupe's do, and a window with a text view.
@MainActor
private final class TestApp {
    private(set) var menuPresses = 0
    private let window: NSWindow
    private let target = MenuTarget()
    private let savedMenu: NSMenu?

    init() throws {
        let app = NSApplication.shared
        TextEditingKeys.start()
        savedMenu = app.mainMenu
        let menu = NSMenu()
        let item = NSMenuItem(title: "Review", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "Review")
        for (key, modifiers) in [(String(downArrow), NSEvent.ModifierFlags.command), ("]", [.command, .shift])] {
            let entry = NSMenuItem(title: "Act on \(key)", action: #selector(MenuTarget.act), keyEquivalent: key)
            entry.keyEquivalentModifierMask = modifiers
            entry.target = target
            submenu.addItem(entry)
        }
        item.submenu = submenu
        menu.addItem(item)
        app.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        target.pressed = { [weak self] in self?.menuPresses += 1 }
        try #require(window.windowNumber > 0)
    }

    deinit {
        MainActor.assumeIsolated {
            window.close()
            NSApplication.shared.mainMenu = savedMenu
        }
    }

    func focusText(_ string: String, editable: Bool) -> NSTextView {
        let text = NSTextView(frame: window.contentLayoutRect)
        text.string = string
        text.isEditable = editable
        text.isSelectable = true
        window.contentView = text
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 0, length: 0))
        return text
    }

    func press(_ key: Character, modifiers: NSEvent.ModifierFlags) {
        let characters = String(key)
        let isFunctionKey = key.unicodeScalars.first.map { $0.value >= 0xF700 } ?? false
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: isFunctionKey ? modifiers.union([.function, .numericPad]) : modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: modifiers.contains(.control) ? String(UnicodeScalar(UInt8(key.asciiValue! & 0x1F))) : characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode(key)
        )
        if let event { NSApplication.shared.sendEvent(event) }
    }
}

private final class MenuTarget: NSObject {
    var pressed: () -> Void = {}

    @objc func act() { pressed() }
}

private let downArrow = Character(UnicodeScalar(NSDownArrowFunctionKey)!)
private let upArrow = Character(UnicodeScalar(NSUpArrowFunctionKey)!)
private let backspace = Character(UnicodeScalar(0x7F))

/// The virtual key code a key is typed with, which AppKit's key bindings read.
private func keyCode(_ key: Character) -> UInt16 {
    switch key {
    case downArrow: 125
    case upArrow: 126
    case backspace: 51
    case "e": 14
    case "]": 30
    default: 0
    }
}
