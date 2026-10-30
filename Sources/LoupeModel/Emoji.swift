/// An emoji GitHub's markdown takes as `:name:`, and the character it stands for. GitHub's own,
/// such as `:shipit:`, are images with no character.
public struct Emoji: Hashable, Sendable {
    public let name: String
    public let character: String?

    public init(name: String, character: String?) {
        self.name = name
        self.character = character
    }

    /// What completing it puts in the text: the character, or for GitHub's own the `:name:`
    /// GitHub renders as its image.
    public var insertion: String { character ?? ":\(name):" }

    /// The emoji whose names have `partial` in them, ignoring case, at most `limit`: those
    /// starting with it first, shortest first, then the rest by name, as github.com offers them.
    public static func matches(_ emoji: [Emoji], for partial: String, limit: Int = 20) -> [Emoji] {
        let partial = partial.lowercased()
        guard !partial.isEmpty else { return [] }
        let found = emoji.filter { $0.name.lowercased().contains(partial) }
        let (starting, inside) = (found.filter { $0.name.lowercased().hasPrefix(partial) }, found.filter { !$0.name.lowercased().hasPrefix(partial) })
        let ordered = starting.sorted { ($0.name.count, $0.name) < ($1.name.count, $1.name) } + inside.sorted { $0.name < $1.name }
        return Array(ordered.prefix(limit))
    }
}
