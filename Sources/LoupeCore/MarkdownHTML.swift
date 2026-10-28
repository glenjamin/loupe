import Foundation

/// A markdown file as GitHub renders it, as one page in the conversation's template and styles,
/// so it reads as it does on github.com.
public enum MarkdownHTML {
    /// Whether Linguist, and so GitHub, takes `path` for Markdown, which GitHub shows rendered.
    public static func isMarkdown(_ path: String) -> Bool {
        Linguist.languages.languages(forPath: path).contains("Markdown")
    }

    /// A file's text with any YAML frontmatter fenced as a `yaml` code block, as GitHub's renderer
    /// doesn't know frontmatter and would make it a rule and a heading. Any other text is unchanged.
    public static func fencingFrontmatter(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, isFence(first, closing: false),
              let end = lines.dropFirst().firstIndex(where: { isFence($0, closing: true) })
        else { return text }
        let yaml = lines[1..<end].joined(separator: "\n")
        let longestBackticks = yaml.split(whereSeparator: { $0 != "`" }).map(\.count).max() ?? 0
        let fence = String(repeating: "`", count: max(3, longestBackticks + 1))
        let rest = lines[(end + 1)...].joined(separator: "\n")
        return "\(fence)yaml\n\(yaml)\n\(fence)\n\(rest)"
    }

    /// The page for `renderedHTML`, GitHub's rendering of a file, which goes in verbatim as GitHub
    /// has already sanitised it.
    public static func page(_ renderedHTML: String, template: String, stylesheet: String) -> String {
        ConversationHTML.fill(template, layout: "file", content: #"<article class="body markdown-body">\#(renderedHTML)</article>"#, stylesheet: stylesheet)
    }

    /// The page for `renderedHTML`, GitHub's rendering of a draft, styled as a comment's body is
    /// in the conversation. It goes in verbatim, as GitHub has already sanitised it.
    public static func draftPage(_ renderedHTML: String, template: String, stylesheet: String) -> String {
        ConversationHTML.fill(template, layout: "draft", content: #"<div class="body markdown-body">\#(renderedHTML)</div>"#, stylesheet: stylesheet)
    }
}

/// Whether `line` opens frontmatter, or closes it, which YAML's document end also does.
private func isFence(_ line: Substring, closing: Bool) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces.union(["\r"]))
    return trimmed == "---" || (closing && trimmed == "...")
}
