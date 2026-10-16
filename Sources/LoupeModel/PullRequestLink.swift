import Foundation

/// A link to a PR on github.com, as PRs' descriptions and comments link to each other, whichever
/// part of the PR it points at.
public struct PullRequestLink: Sendable, Hashable {
    /// `owner/name`.
    public let repository: String
    public let number: Int

    public init(repository: String, number: Int) {
        self.repository = repository
        self.number = number
    }

    /// From `https://github.com/<owner>/<name>/pull/<number>`, with or without anything after
    /// it, such as `/files`, a query or a comment's `#issuecomment-…`. Loupe's own scheme names a
    /// PR the same way, as `loupe://github.com/…` (a GitHub link with its scheme swapped) or
    /// `loupe:///<owner>/<name>/pull/<number>`. Nil for any other URL.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        let host = url.host()?.lowercased() ?? ""
        let gitHubHosts = ["github.com", "www.github.com"]
        switch scheme {
        case "http", "https": guard gitHubHosts.contains(host) else { return nil }
        case "loupe": guard host.isEmpty || gitHubHosts.contains(host) else { return nil }
        default: return nil
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 4, parts[2] == "pull",
              let number = Int(parts[3]), number > 0, parts[3].allSatisfy(\.isASCIIDigit),
              !parts[0].isEmpty, !parts[1].isEmpty
        else { return nil }
        repository = "\(parts[0])/\(parts[1])"
        self.number = number
    }
}

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
