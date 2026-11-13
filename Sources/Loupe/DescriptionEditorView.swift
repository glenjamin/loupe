import AppKit
import LoupeCore
import LoupeInbox
import LoupeModel
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

/// The commented lines a composer offers as a suggestion, put in at the cursor each time `count`
/// goes up, as github.com's "Add a suggestion" does; `request` asks for one.
struct SuggestionRequests {
    let lines: [String]
    let count: Int
    let request: () -> Void
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
    /// Counts requests to take the focus with the cursor at the end, as after a quote is added.
    var focusRequests = 0
    /// Told how tall the text is laid out whenever that changes, for a box that fits it.
    var contentHeightChanged: ((CGFloat) -> Void)?
    /// The suggestion it offers, if any, put in at the cursor on each request and on ⌘G.
    var suggestion: SuggestionRequests?
    /// The emoji a `:` and part of a name completes to.
    var emojis: () -> [Emoji] = { [] }
    /// Who an `@` and part of a login or name completes to, in the order to offer them.
    var mentions: () -> [Reviewer] = { [] }
    /// Counts the fetches of who to mention, each offering again a mention being typed.
    var mentionsFetched = 0

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
        context.coordinator.suggestionRequests = suggestion?.count ?? 0
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
        textView.onContentHeight = contentHeightChanged.map { changed in
            // Later, as it's often learnt while SwiftUI is updating the view.
            { height in DispatchQueue.main.async { changed(height) } }
        }
        textView.reportContentHeight()
        // Typing can start straight away, and again on coming back from the preview, which is
        // switched to and from this box alone.
        let toggled = context.coordinator.wasPreviewing != isPreviewing
        context.coordinator.wasPreviewing = isPreviewing
        if !context.coordinator.hasFocused || toggled, let window = textView.window {
            context.coordinator.hasFocused = window.makeFirstResponder(textView)
        }
        if focusRequests != context.coordinator.focusRequests {
            context.coordinator.focusRequests = focusRequests
            textView.focusAtEnd()
        }
        textView.onSuggest = suggestion?.request
        textView.emojis = emojis
        textView.mentions = mentions
        if mentionsFetched != context.coordinator.mentionsFetched {
            context.coordinator.mentionsFetched = mentionsFetched
            textView.offerMentionsAgain()
        }
        // A request made over the preview waits for Write, as the text takes no typing there.
        if let suggestion, suggestion.count != context.coordinator.suggestionRequests, !isPreviewing {
            context.coordinator.suggestionRequests = suggestion.count
            textView.insertSuggestion(of: suggestion.lines)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var hasFocused = false
        var wasPreviewing = false
        /// The focus requests acted on.
        var focusRequests = 0
        /// The suggestion requests acted on.
        var suggestionRequests = 0
        /// The fetches of who to mention acted on.
        var mentionsFetched = 0

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
final class MarkdownEditingTextView: NSTextView, KeepsTextKeys {
    var onSave: () -> Void = {}
    var onAlternateSave: (() -> Void)?
    var onCancel: () -> Void = {}
    var onTogglePreview: (() -> Void)?
    /// Told the height of the laid-out text whenever it changes.
    var onContentHeight: ((CGFloat) -> Void)?
    /// What ⌘G does, as on github.com, if anything.
    var onSuggest: (() -> Void)?
    /// The emoji a `:` and part of a name completes to; none offered while it's empty.
    var emojis: () -> [Emoji] = { [] }
    /// Who an `@` and part of a login or name completes to; none offered while it's empty.
    var mentions: () -> [Reviewer] = { [] }
    /// What's in the completion list, by the line shown for each.
    private var offered: [String: Completion] = [:]
    /// Set while completing changes the text, so that change doesn't complete again.
    private var isCompleting = false
    var isPreviewing = false
    private var reportedHeight: CGFloat?
    /// The fixed end of a selection made by code words, so the other end moves on the next one.
    private var wordSelectionAnchor: Int?
    /// Whether to take the focus once it's in a window.
    private var focusesInWindow = false

    /// Takes the focus with the cursor at the end, now or once it's in a window.
    func focusAtEnd() {
        guard let window, window.makeFirstResponder(self) else {
            focusesInWindow = true
            return
        }
        focusesInWindow = false
        let end = NSRange(location: (string as NSString).length, length: 0)
        setSelectedRange(end)
        scrollRangeToVisible(end)
    }

    /// Tells `onContentHeight` the text's height, insets included, if it's changed.
    func reportContentHeight() {
        // Until it has a width, every character would be a line of its own.
        guard let onContentHeight, frame.width > 0, let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        let height = ceil(layoutManager.usedRect(for: textContainer).height + textContainerInset.height * 2)
        guard height != reportedHeight else { return }
        reportedHeight = height
        onContentHeight(height)
    }

    override func didChangeText() {
        super.didChangeText()
        reportContentHeight()
        // Offered as the name's typed, as on github.com; inserting one changes the text too.
        if !isCompleting, completionRange() != nil {
            isCompleting = true
            complete(nil)
            isCompleting = false
        }
    }

    /// Offers who to mention again for an `@` being typed, as when more people have come.
    func offerMentionsAgain() {
        guard !isCompleting, completionRange()?.trigger == .mention else { return }
        isCompleting = true
        complete(nil)
        isCompleting = false
    }

    override var rangeForUserCompletion: NSRange {
        completionRange()?.range ?? super.rangeForUserCompletion
    }

    /// For a `:` and part of a name, the emoji named so, each shown with its character; for an
    /// `@` and part of a login or name, who it could mention, each shown with their name.
    override func completions(forPartialWordRange charRange: NSRange, indexOfSelectedItem index: UnsafeMutablePointer<Int>) -> [String]? {
        guard let (range, trigger) = completionRange(), range == charRange else {
            return super.completions(forPartialWordRange: charRange, indexOfSelectedItem: index)
        }
        let typed = String((string as NSString).substring(with: charRange).dropFirst())
        let matches: [Completion] = switch trigger {
        case .emoji: Emoji.matches(emojis(), for: typed).map(Completion.emoji)
        case .mention: Mentions.matches(mentions(), for: typed).map(Completion.mention)
        }
        offered = Dictionary(matches.map { ($0.offer, $0) }, uniquingKeysWith: { first, _ in first })
        index.pointee = 0
        return matches.isEmpty ? nil : matches.map(\.offer)
    }

    /// Puts the chosen emoji's character, or the `@login` and a space, in place of what was typed
    /// on ↩ or Tab, and nothing while moving through the list, so what's typed stays as it was
    /// until one is chosen.
    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        guard let completion = offered[word] else {
            return super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        }
        guard flag, [NSTextMovement.return.rawValue, NSTextMovement.tab.rawValue].contains(movement) else { return }
        offered = [:]
        let insertion = completion.insertion
        guard shouldChangeText(in: charRange, replacementString: insertion) else { return }
        isCompleting = true
        replaceCharacters(in: charRange, with: insertion)
        didChangeText()
        isCompleting = false
        setSelectedRange(NSRange(location: charRange.location + (insertion as NSString).length, length: 0))
    }

    /// The `:` or `@` and what's typed after it up to the cursor, when that's how the word being
    /// typed starts: after a space, a bracket or the start of a line, as GitHub takes `:name:`
    /// and mentions, so a URL's `:`, a time's or an email address's `@` isn't one. An emoji
    /// waits for two characters of its name, as there are so many; a mention is offered at once.
    private func completionRange() -> (range: NSRange, trigger: CompletionTrigger)? {
        let cursor = selectedRange()
        guard cursor.length == 0, cursor.location > 0 else { return nil }
        let text = string as NSString
        var start = cursor.location
        while start > 0, let scalar = Unicode.Scalar(text.character(at: start - 1)), Self.completedCharacters.contains(scalar) {
            start -= 1
        }
        guard start > 0 else { return nil }
        let trigger: CompletionTrigger
        switch text.character(at: start - 1) {
        case UInt16(UInt8(ascii: ":")) where cursor.location - start >= 2 && !text.substring(with: NSRange(location: start, length: cursor.location - start)).contains("/"):
            trigger = .emoji
        case UInt16(UInt8(ascii: "@")):
            trigger = .mention
        default:
            return nil
        }
        let mark = start - 1
        if mark > 0, let before = Unicode.Scalar(text.character(at: mark - 1)), !CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "([{")).contains(before) {
            return nil
        }
        return (NSRange(location: mark, length: cursor.location - mark), trigger)
    }

    /// Those of emoji names, logins, and teams' `org/slug`.
    private static let completedCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-/")

    override func setFrameSize(_ newSize: NSSize) {
        let rewraps = newSize.width != frame.width
        super.setFrameSize(newSize)
        if rewraps { reportContentHeight() }
    }

    /// Puts a suggestion of `lines` in place of the selection, as one undoable change, and takes
    /// the focus with the cursor inside it.
    func insertSuggestion(of lines: [String]) {
        let edit = SuggestedChange.insertion(of: lines, into: string, replacing: selectedRange())
        guard shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return }
        replaceCharacters(in: edit.range, with: edit.replacement)
        didChangeText()
        window?.makeFirstResponder(self)
        setSelectedRange(edit.selection)
        scrollRangeToVisible(edit.selection)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if focusesInWindow, window != nil { focusAtEnd() }
    }

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
        if let onSuggest, window?.firstResponder === self, modifiers == .command, event.charactersIgnoringModifiers?.lowercased() == "g" {
            onSuggest()
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

private enum CompletionTrigger {
    case emoji, mention
}

/// What the completion list offers: an emoji, or someone to mention.
private enum Completion {
    case emoji(Emoji)
    case mention(Reviewer)

    /// Its line in the list.
    var offer: String {
        switch self {
        case let .emoji(emoji): "\(emoji.character ?? "·") :\(emoji.name):"
        case let .mention(person): person.name.map { "@\(person.login)  \($0)" } ?? "@\(person.login)"
        }
    }

    /// What choosing it puts in the text.
    var insertion: String {
        switch self {
        case let .emoji(emoji): emoji.insertion
        case let .mention(person): "@\(person.login) "
        }
    }
}

private let returnKeyCode: UInt16 = 36
private let enterKeyCode: UInt16 = 76
private let escapeKeyCode: UInt16 = 53
private let leftArrowKeyCode: UInt16 = 123
private let rightArrowKeyCode: UInt16 = 124
