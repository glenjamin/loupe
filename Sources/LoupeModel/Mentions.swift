/// Who a comment's `@` and part of a login or name completes to.
public enum Mentions {
    /// Of `people`, in their order, those whose login or name has `partial` in them, ignoring
    /// case, at most `limit`: logins starting with it first, then names with a word starting with
    /// it, then the rest. With nothing typed yet, the first of them.
    public static func matches(_ people: [Reviewer], for partial: String, limit: Int = 10) -> [Reviewer] {
        let partial = partial.lowercased()
        guard !partial.isEmpty else { return Array(people.prefix(limit)) }
        let ranked = people.compactMap { person -> (rank: Int, person: Reviewer)? in
            let login = person.login.lowercased()
            let name = person.name?.lowercased() ?? ""
            if login.hasPrefix(partial) { return (0, person) }
            if name.split(whereSeparator: { $0 == " " || $0 == "-" }).contains(where: { $0.hasPrefix(partial) }) { return (1, person) }
            if login.contains(partial) || name.contains(partial) { return (2, person) }
            return nil
        }
        // Sorting by rank alone would be unstable, so each keeps its place within its rank.
        return Array(ranked.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element.person).prefix(limit))
    }
}
