import AppKit
import LoupeCore
import LoupeInbox
import LoupeModel
import SwiftUI

/// The blocks a file's diff lays over its rows for its review threads: one under each line
/// threads end on, and one after the last row for those with nowhere in the diff to go.
@MainActor
func threadBlocks(for threads: FileThreads, in tab: PullRequestTab) -> [DiffBlockContent] {
    var blocks = threads.anchored.map { line in
        DiffBlockContent(
            id: "threads:\(line.side.rawValue):\(line.line)",
            placement: .after(side: line.side, line: line.line),
            view: AnyView(ThreadStack(tab: tab, threads: line.threads))
        )
    }
    if !threads.elsewhere.isEmpty {
        blocks.append(DiffBlockContent(id: "threads:elsewhere", placement: .end, view: AnyView(ElsewhereThreads(tab: tab, threads: threads.elsewhere))))
    }
    return blocks
}

/// The threads ending on one line, one card each, indented to sit under the code.
private struct ThreadStack: View {
    let tab: PullRequestTab
    let threads: [ReviewThread]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(threads) { thread in
                ThreadCard(tab: tab, thread: thread, showsHunk: false)
            }
        }
        .modifier(BlockInset())
    }
}

/// Threads the diff has no line for: outdated ones, ones on the whole file, and ones on lines
/// it doesn't show. Each shows the snippet of diff it was made on, so nothing is lost.
private struct ElsewhereThreads: View {
    let tab: PullRequestTab
    let threads: [ReviewThread]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Not on the current diff")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(threads) { thread in
                ThreadCard(tab: tab, thread: thread, showsHunk: !thread.diffHunk.isEmpty)
            }
        }
        .modifier(BlockInset())
    }
}

/// A review thread: its comments in order under a header naming its lines. A resolved one is
/// a single quiet line until opened.
private struct ThreadCard: View {
    let tab: PullRequestTab
    let thread: ReviewThread
    let showsHunk: Bool

    var body: some View {
        let activity = tab.threadActivity
        if thread.isResolved && !activity.expanded.contains(thread.id) {
            Button { activity.expanded.insert(thread.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                    Text(verbatim: resolvedSummary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
            .help("Show this resolved conversation")
        } else {
            VStack(alignment: .leading, spacing: 0) {
                header
                if showsHunk {
                    Divider()
                    HunkSnippet(hunk: thread.diffHunk)
                }
                ForEach(thread.comments) { comment in
                    Divider()
                    CommentView(comment: comment, viewer: tab.viewer, activity: activity)
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
        }
    }

    /// `Resolved · 4 comments · login`, naming who started it.
    private var resolvedSummary: String {
        let count = thread.comments.count
        let starter = thread.comments.first?.author?.login
        return (["Resolved", "\(count) \(count == 1 ? "comment" : "comments")"] + (starter.map { [$0] } ?? [])).joined(separator: " · ")
    }

    private var header: some View {
        HStack(spacing: 8) {
            if thread.isResolved {
                Button { tab.threadActivity.expanded.remove(thread.id) } label: {
                    Label("Resolved", systemImage: "checkmark.circle")
                }
                .buttonStyle(.plain)
                .help("Fold this resolved conversation")
            }
            Text(verbatim: place)
            if thread.isOutdated {
                Text("Outdated")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.5)))
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.bar)
    }

    /// Which lines it's on, where it was made for an outdated thread.
    private var place: String {
        guard let lines = thread.lines else { return "On the file" }
        let side = thread.side == .left ? " (old)" : ""
        let prefix = thread.isOutdated && thread.line == nil ? "Was on " : ""
        let range = lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)–\(lines.upperBound)"
        let text = prefix + range + side
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

/// One comment: who wrote it and when, over its body. A hidden one is a line saying so, which
/// shows it when clicked.
private struct CommentView: View {
    let comment: ThreadComment
    let viewer: String?
    let activity: ThreadActivity

    var body: some View {
        if comment.isMinimized && !activity.expanded.contains(comment.id) {
            Button { activity.expanded.insert(comment.id) } label: {
                HStack(spacing: 6) {
                    Image(systemName: "eye.slash")
                    Text(verbatim: hiddenSummary)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .help("Show this hidden comment")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: author).fontWeight(.semibold)
                    TimelineView(.everyMinute) { _ in
                        Text(verbatim: comment.createdAt.formatted(.relative(presentation: .named)))
                            .foregroundStyle(.secondary)
                    }
                    .help(comment.createdAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.callout)
                CommentBody(blocks: commentBlocks(comment.bodyHTML))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }

    private var author: String {
        guard let login = comment.author?.login else { return "ghost" }
        return login == viewer ? "\(login) (you)" : login
    }

    private var hiddenSummary: String {
        let reason = comment.minimizedReason.map { " as \($0.lowercased().replacingOccurrences(of: "_", with: " "))" } ?? ""
        return "\(comment.author?.login ?? "ghost")'s comment was hidden\(reason)"
    }
}

/// A comment's body, laid out natively from GitHub's rendering of it.
struct CommentBody: View {
    let blocks: [CommentBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case let .text(text, indent):
                    Text(text)
                        .padding(.leading, CGFloat(indent) * 16)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                case let .code(code):
                    Text(verbatim: code)
                        .font(.system(.callout, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 4))
                case let .quote(inner):
                    HStack(alignment: .top, spacing: 8) {
                        Capsule().fill(.quaternary).frame(width: 3)
                        CommentBody(blocks: inner).foregroundStyle(.secondary)
                    }
                case .rule:
                    Divider()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The end of the diff an outdated thread was made on, as GitHub kept it.
private struct HunkSnippet: View {
    let hunk: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line.isEmpty ? " " : line)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(background(of: line))
            }
        }
        .font(.system(size: 12, design: .monospaced))
        .padding(.vertical, 4)
    }

    /// The last few lines, which end on the commented one, as github.com shows.
    private var lines: [String] {
        Array(hunk.split(separator: "\n", omittingEmptySubsequences: false).dropFirst().suffix(4).map(String.init))
    }

    private func background(of line: String) -> Color {
        if line.hasPrefix("+") { return Color(nsColor: DiffColors.additionBackground) }
        if line.hasPrefix("-") { return Color(nsColor: DiffColors.deletionBackground) }
        return .clear
    }
}

/// Sets a thread block in from the gutter, so it reads as belonging to the code above it, and
/// keeps it to a readable width.
private struct BlockInset: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: 820, alignment: .leading)
            .padding(.leading, 48)
            .padding(.trailing, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.secondary.opacity(0.05))
    }
}

/// The blocks of a comment's HTML, worked out once per body while the app runs.
@MainActor
private func commentBlocks(_ html: String) -> [CommentBlock] {
    if let blocks = parsedComments[html] { return blocks }
    let blocks = CommentBlock.blocks(fromHTML: html)
    parsedComments[html] = blocks
    return blocks
}

@MainActor private var parsedComments: [String: [CommentBlock]] = [:]
