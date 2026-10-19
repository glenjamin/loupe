import AppKit
import LoupeCore
import LoupeInbox
import SwiftUI

/// Edits the PR's description in place of the conversation: the description as it is on GitHub
/// now, as plain monospaced markdown, with Cancel and Save. ⌘↩ saves and Esc cancels, asking
/// first if there are changes.
struct DescriptionEditorView: View {
    @Bindable var editor: DescriptionEditor
    let tab: PullRequestTab
    @State private var confirmsDiscard = false

    var body: some View {
        Group {
            switch editor.phase {
            case .fetching:
                ProgressView("Fetching the description from GitHub…")
            case let .fetchFailed(message):
                ContentUnavailableView {
                    Label("Couldn't fetch the description", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("It's edited as it is on GitHub now, so changes made there aren't lost.\n\(message)")
                        .textSelection(.enabled)
                } actions: {
                    Button("Retry") { Task { await editor.fetch() } }
                    Button("Cancel") { tab.closeDescriptionEditor() }
                        .keyboardShortcut(.cancelAction)
                }
            case .editing, .saving:
                VStack(spacing: 0) {
                    MarkdownEditor(text: $editor.draft, isEditable: editor.phase == .editing, tab: tab, save: save, cancel: cancel)
                    Divider()
                    footer
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .alert("Discard your changes to the description?", isPresented: $confirmsDiscard) {
            Button("Discard Changes", role: .destructive) { tab.closeDescriptionEditor() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("They haven't been saved to GitHub.")
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = editor.saveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.diffDanger)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .help(error)
            }
            HStack(spacing: 8) {
                Text("The description is GitHub-flavoured markdown.")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if editor.phase == .saving {
                    ProgressView()
                        .controlSize(.small)
                    Text("Saving…")
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(editor.phase == .saving)
                Button("Save", action: save)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(!editor.canSave)
                    .help("Save to GitHub (⌘↩)")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func save() {
        guard editor.canSave else { return }
        Task { await tab.saveDescription() }
    }

    private func cancel() {
        guard editor.phase != .saving else { return }
        if editor.hasChanges {
            confirmsDiscard = true
        } else {
            tab.closeDescriptionEditor()
        }
    }
}

/// A plain-text `NSTextView` for markdown: monospaced, with no spelling, quote, dash or link
/// substitutions, which would change what's sent to GitHub.
struct MarkdownTextView: NSViewRepresentable {
    @Binding var text: String
    let isEditable: Bool
    let save: () -> Void
    /// What ⌘⇧↩ does, if anything; without it the key is the text view's own.
    var alternateSave: (() -> Void)?
    let cancel: () -> Void
    var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
    /// Whether a preview covers it, while it keeps the keyboard but takes no typing.
    var isPreviewing = false
    /// What ⌘⇧P does, if anything.
    var togglePreview: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        let textView = MarkdownEditingTextView(frame: NSRect(origin: .zero, size: scrollView.contentSize))
        textView.configureForMarkdown()
        textView.font = font
        textView.string = text
        textView.delegate = context.coordinator
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let textView = scrollView.documentView as? MarkdownEditingTextView else { return }
        if textView.string != text { textView.string = text }
        textView.isEditable = isEditable && !isPreviewing
        textView.isPreviewing = isPreviewing
        textView.onSave = save
        textView.onAlternateSave = alternateSave
        textView.onCancel = cancel
        textView.onTogglePreview = togglePreview
        // Typing can start straight away, and again on coming back from the preview, which is
        // switched to and from this box alone.
        let toggled = context.coordinator.wasPreviewing != isPreviewing
        context.coordinator.wasPreviewing = isPreviewing
        if !context.coordinator.hasFocused || toggled, let window = textView.window {
            context.coordinator.hasFocused = window.makeFirstResponder(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var hasFocused = false
        var wasPreviewing = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// Takes ⌘↩, ⌘⇧↩ when given something to do with it, and Esc itself while it has focus, as a
/// text view would otherwise insert a newline or offer completions. ⌥← and ⌥→ move by code words
/// rather than natural-language ones, as comments are mostly about code; with ⇧ they select.
/// ⌘⇧P switches to and from a preview while it has focus, ahead of any menu's use of the key;
/// under a preview it ignores every other key, so the hidden text and selection stay as they were.
final class MarkdownEditingTextView: NSTextView {
    var onSave: () -> Void = {}
    var onAlternateSave: (() -> Void)?
    var onCancel: () -> Void = {}
    var onTogglePreview: (() -> Void)?
    var isPreviewing = false
    /// The fixed end of a selection made by code words, so the other end moves on the next one.
    private var wordSelectionAnchor: Int?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let isReturn = event.keyCode == returnKeyCode || event.keyCode == enterKeyCode
        let arrowModifiers = modifiers.intersection([.command, .shift, .option, .control])
        let arrow: CodeWordDirection? = switch event.keyCode {
        case leftArrowKeyCode: .left
        case rightArrowKeyCode: .right
        default: nil
        }
        if isReturn, modifiers == .command {
            onSave()
        } else if isReturn, modifiers == [.command, .shift], let onAlternateSave {
            onAlternateSave()
        } else if isPreviewing {
            if event.keyCode == escapeKeyCode { onCancel() }
        } else if let arrow, arrowModifiers == .option || arrowModifiers == [.option, .shift] {
            moveByCodeWord(arrow, extendingSelection: arrowModifiers.contains(.shift))
        } else {
            super.keyDown(with: event)
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if let onTogglePreview, window?.firstResponder === self, modifiers == [.command, .shift],
           event.charactersIgnoringModifiers?.lowercased() == "p" {
            onTogglePreview()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }


    override func cancelOperation(_ sender: Any?) {
        onCancel()
    }

    func configureForMarkdown() {
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainerInset = NSSize(width: 8, height: 10)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textColor = .textColor
        backgroundColor = .textBackgroundColor
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
    }

    private func moveByCodeWord(_ direction: CodeWordDirection, extendingSelection: Bool) {
        let selection = selectedRange()
        // The end that moves is the one away from the anchor, or else the end it's moving towards.
        let anchor = if let wordSelectionAnchor, selection.length > 0,
                        wordSelectionAnchor == selection.lowerBound || wordSelectionAnchor == selection.upperBound {
            wordSelectionAnchor
        } else {
            direction == .left ? selection.upperBound : selection.lowerBound
        }
        let head = anchor == selection.lowerBound ? selection.upperBound : selection.lowerBound
        let target = codeWordBoundary(in: string, from: head, direction)
        if extendingSelection {
            wordSelectionAnchor = anchor
            setSelectedRange(NSRange(location: min(anchor, target), length: abs(target - anchor)))
        } else {
            wordSelectionAnchor = nil
            setSelectedRange(NSRange(location: target, length: 0))
        }
        scrollRangeToVisible(NSRange(location: target, length: 0))
    }
}

private let returnKeyCode: UInt16 = 36
private let enterKeyCode: UInt16 = 76
private let escapeKeyCode: UInt16 = 53
private let leftArrowKeyCode: UInt16 = 123
private let rightArrowKeyCode: UInt16 = 124
