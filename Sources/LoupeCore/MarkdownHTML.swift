import Foundation

/// A markdown file as GitHub renders it, as one page in the conversation's template and styles,
/// so it reads as it does on github.com.
public enum MarkdownHTML {
    /// Whether Linguist, and so GitHub, takes `path` for Markdown, which GitHub shows rendered.
    public static func isMarkdown(_ path: String) -> Bool {
        Linguist.languages.languages(forPath: path).contains("Markdown")
    }

    /// The page for `renderedHTML`, GitHub's rendering of a file, which goes in verbatim as GitHub
    /// has already sanitised it.
    public static func page(_ renderedHTML: String, template: String, stylesheet: String) -> String {
        ConversationHTML.fill(template, layout: "file", content: #"<article class="body markdown-body">\#(renderedHTML)</article>"#, stylesheet: stylesheet)
    }
}
