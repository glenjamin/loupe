import AppKit

/// Gives the standard text-editing keys to the text that has the focus, ahead of the menus' key
/// equivalents and the app's own key monitors, so ⌘↓ in a comment goes to its end rather than
/// to the next file. The keys are the arrows, Home, End, Page Up and Down, and both deletes,
/// whatever the modifiers, and ⌃ with a letter, macOS's Emacs-style bindings. Everything else,
/// such as ⌘↩, Esc, Tab and ⌘-letters, goes the usual way, so a dialog's buttons and the app's
/// shortcuts still take those.
@MainActor
public enum TextEditingKeys {
    private static var monitor: Any?

    /// Starts routing the keys for every window of the app; calling it again does nothing.
    public static func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Local monitors run on the main thread, where the event came from.
            nonisolated(unsafe) let event = event
            return MainActor.assumeIsolated { route(event) } ? nil : event
        }
    }

    /// Whether the focus in `window` is somewhere text is typed: an editable text view or a
    /// field's editor, or a text view that keeps the keys while it can't be typed in for now.
    public static func isTyping(in window: NSWindow) -> Bool {
        guard let text = window.firstResponder as? NSTextView else { return false }
        return text.isEditable || text is KeepsTextKeys
    }

    /// Hands `event` straight to the focused text, past the menus, if it's a text-editing key
    /// and text has the focus; returns whether it did.
    static func route(_ event: NSEvent) -> Bool {
        guard let window = event.window, isTextEditingKey(event), isTyping(in: window) else { return false }
        // The window delivers a key down to its first responder without the menus seeing it.
        window.sendEvent(event)
        return true
    }
}

/// A text view that keeps the text-editing keys while it has the focus, even while it can't be
/// typed in, as a markdown box does under its preview.
public protocol KeepsTextKeys: NSTextView {}

/// Whether `event` is one of the keys that move through or delete text.
@MainActor
private func isTextEditingKey(_ event: NSEvent) -> Bool {
    let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
    if let special = event.specialKey, textEditingSpecialKeys.contains(special) { return true }
    guard modifiers.contains(.control), !modifiers.contains(.command),
          let key = event.charactersIgnoringModifiers?.lowercased(), key.count == 1
    else { return false }
    return key.unicodeScalars.allSatisfy { ("a"..."z").contains($0) }
}

@MainActor
private let textEditingSpecialKeys: Set<NSEvent.SpecialKey> = [
    .upArrow, .downArrow, .leftArrow, .rightArrow, .home, .end, .pageUp, .pageDown, .delete, .backspace, .deleteForward,
]
