import Foundation

/// What CI's diff-book comment on a PR says of its visual baselines: how many differ from the
/// base branch, each story and how it changed, how many stories were rendered, and where the
/// interactive report is. Recognised by the comment's `<!-- diff-book-review -->` marker; only
/// the marker and the report's link are needed, so a change of wording loses the counts or
/// stories rather than the report.
public struct VisualReview: Sendable, Equatable {
    /// The comment it was read from, which CI edits in place on each run.
    public var commentId: String
    /// When the comment was last edited, or made if never.
    public var updatedAt: Date
    /// The comment's first heading, such as "Visual baselines changed".
    public var title: String?
    public var reportURL: URL
    /// The CI job's artifacts tab, where the report is if its own link doesn't resolve.
    public var artifactsURL: URL?
    /// Nil when the comment's wording couldn't be read for them.
    public var counts: Counts?
    /// In the comment's order.
    public var stories: [Story]
    /// How many stories were rendered, when the comment says.
    public var rendered: Rendered?

    public struct Counts: Sendable, Equatable {
        public var changed: Int
        public var new: Int
        public var removed: Int

        public init(changed: Int, new: Int, removed: Int) {
            self.changed = changed
            self.new = new
            self.removed = removed
        }

        public var total: Int { changed + new + removed }
    }

    /// How many stories were rendered of how many there are: only those that can reach a file
    /// the branch changed are.
    public struct Rendered: Sendable, Equatable {
        public var count: Int
        public var total: Int

        public init(count: Int, total: Int) {
            self.count = count
            self.total = total
        }
    }

    public struct Story: Sendable, Equatable, Identifiable {
        public var name: String
        public var status: Status

        public init(name: String, status: Status) {
            self.name = name
            self.status = status
        }

        public var id: String { name }
    }

    public enum Status: Sendable, Equatable {
        case changed
        case new
        case removed
        /// Worded some other way, kept as written.
        case other(String)
    }

    public init(commentId: String, updatedAt: Date, title: String? = nil, reportURL: URL, artifactsURL: URL? = nil, counts: Counts? = nil, stories: [Story] = [], rendered: Rendered? = nil) {
        self.commentId = commentId
        self.updatedAt = updatedAt
        self.title = title
        self.reportURL = reportURL
        self.artifactsURL = artifactsURL
        self.counts = counts
        self.stories = stories
        self.rendered = rendered
    }

    /// How many baselines differ: the counts' total, or the stories listed when the counts
    /// couldn't be read; nil when neither could.
    public var changeCount: Int? {
        counts?.total ?? (stories.isEmpty ? nil : stories.count)
    }

    /// Whether there's anything to look at, which is also so when it couldn't be counted.
    public var hasChanges: Bool {
        changeCount.map { $0 > 0 } ?? true
    }

    /// The report in the most recently updated diff-book comment of the timeline, if any has one.
    public static func latest(in items: [TimelineItem]) -> VisualReview? {
        items.compactMap { item -> VisualReview? in
            guard case .comment = item.event, let body = item.body else { return nil }
            return VisualReview(commentId: item.id, markdown: body, updatedAt: item.updatedAt ?? item.date)
        }
        .max { $0.updatedAt < $1.updatedAt }
    }

    /// Reads a diff-book comment's markdown; nil for any other comment, or one with no link to
    /// a report.
    public init?(commentId: String, markdown: String, updatedAt: Date) {
        guard markdown.contains(Self.marker) else { return nil }
        let links = markdown.matches(of: Self.link).compactMap { match -> (text: String, url: URL)? in
            URL(string: String(match.output.2)).map { (String(match.output.1), $0) }
        }
        let artifacts = links.first { $0.text.localizedCaseInsensitiveContains("artifacts") || $0.url.lastPathComponent == "artifacts" }
        let report = links.first { $0.text.localizedCaseInsensitiveContains("report") }
            ?? links.first { $0.url.pathExtension.lowercased() == "html" }
            ?? links.first { $0.url != artifacts?.url }
        guard let report else { return nil }
        self.init(commentId: commentId, updatedAt: updatedAt, reportURL: report.url, artifactsURL: artifacts?.url)
        title = markdown.firstMatch(of: Self.heading).map { String($0.output.1).trimmingCharacters(in: .whitespaces) }
        if let changed = Self.count("changed", in: markdown), let new = Self.count("new", in: markdown), let removed = Self.count("removed", in: markdown) {
            counts = Counts(changed: changed, new: new, removed: removed)
        }
        stories = markdown.split(whereSeparator: \.isNewline).compactMap { line in
            line.wholeMatch(of: Self.storyLine).map { Story(name: String($0.output.1), status: Status(String($0.output.2))) }
        }
        if let match = markdown.firstMatch(of: Self.renderedLine), let count = Int(match.output.1.filter(\.isNumber)), let total = Int(match.output.2.filter(\.isNumber)) {
            rendered = Rendered(count: count, total: total)
        }
    }

    static let marker = "<!-- diff-book-review -->"
    /// `[text](https://…)`, the text without nested brackets.
    nonisolated(unsafe) static let link = /\[([^\]\n]+)\]\((https?:\/\/[^)\s]+)\)/
    nonisolated(unsafe) static let heading = /(?m)^#{1,6}[ \t]+(.+)$/
    /// A list item naming a story in code, then its status after a dash.
    nonisolated(unsafe) static let storyLine = /\s*[-*+]\s+`([^`]+)`\s*(?:[—–:]|-{1,2})\s*(.+?)\s*/
    nonisolated(unsafe) static let renderedLine = /(\d[\d,]*)\s+of\s+(\d[\d,]*)\s+stor(?:y|ies)\b/

    private static func count(_ word: String, in markdown: String) -> Int? {
        // A number then the word, as in "4 changed, 0 new, 0 removed"; story lines carry no number.
        guard let regex = try? Regex("(\\d+)\\s+\(word)\\b", as: (Substring, Substring).self),
              let match = markdown.firstMatch(of: regex.ignoresCase()) else { return nil }
        return Int(match.output.1)
    }
}

extension VisualReview.Status {
    /// The status as the comment words it.
    init(_ words: String) {
        switch words.lowercased() {
        case "changed": self = .changed
        case "new", "added": self = .new
        case "removed", "deleted": self = .removed
        default: self = .other(words)
        }
    }

    /// The status in a word, for the popover and lists.
    public var label: String {
        switch self {
        case .changed: "changed"
        case .new: "new"
        case .removed: "removed"
        case let .other(words): words
        }
    }
}
