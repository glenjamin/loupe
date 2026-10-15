import AppKit
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
                    MarkdownTextView(text: $editor.draft, isEditable: editor.phase == .editing, save: save, cancel: cancel)
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
    let cancel: () -> Void
    var font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

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
        textView.isEditable = isEditable
        textView.onSave = save
        textView.onCancel = cancel
        // Typing can start straight away.
        if !context.coordinator.hasFocused, let window = textView.window {
            context.coordinator.hasFocused = window.makeFirstResponder(textView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var hasFocused = false

        init(text: Binding<String>) {
            self.text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

/// Takes ⌘↩ and Esc itself while it has focus, as a text view would otherwise insert a newline
/// or offer completions.
final class MarkdownEditingTextView: NSTextView {
    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers == .command, event.keyCode == returnKeyCode || event.keyCode == enterKeyCode {
            onSave()
        } else {
            super.keyDown(with: event)
        }
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
}

private let returnKeyCode: UInt16 = 36
private let enterKeyCode: UInt16 = 76
