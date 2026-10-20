import Foundation

/// A link to a PR on github.com, as PRs' descriptions and comments link to each other, and what
/// part of the PR it points at, where that's something Loupe can show.
public struct PullRequestLink: Sendable, Hashable {
    /// `owner/name`.
    public let repository: String
    public let number: Int
    /// What in the PR the link points at; nil for the PR itself, or a part Loupe has no place for.
    public let target: Target?

    /// A part of a PR a link can point at, named as github.com's URLs name it.
    public enum Target: Sendable, Hashable {
        /// A comment on the PR itself, by its REST id: `#issuecomment-<id>`.
        case comment(Int)
        /// A review, by its REST id: `#pullrequestreview-<id>`.
        case review(Int)
        /// A comment in a review thread, by its REST id: `#discussion_r<id>`, or `#r<id>` on the
        /// files.
        case reviewComment(Int)
        /// The files: the whole PR's, or one commit's by its oid or a prefix of it, and one file
        /// by GitHub's `#diff-<hash>` anchor, the SHA-256 of its path in hex.
        case files(commit: String?, fileHash: String?)
    }

    public init(repository: String, number: Int, target: Target? = nil) {
        self.repository = repository
        self.number = number
        self.target = target
    }

    /// From `https://github.com/<owner>/<name>/pull/<number>`, with or without anything after
    /// it, such as `/files`, a query or a comment's `#issuecomment-…`. Loupe's own scheme names a
    /// PR the same way, as `loupe://github.com/…` (a GitHub link with its scheme swapped) or
    /// `loupe:///<owner>/<name>/pull/<number>`. Nil for any other URL.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        let host = url.host()?.lowercased() ?? ""
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
        target = Target(page: Array(parts.dropFirst(4)), fragment: url.fragment(percentEncoded: false) ?? "")
    }
}

extension PullRequestLink.Target {
    /// From what follows the PR's number in a link's path, such as `files` or `commits/<oid>`,
    /// and its fragment. A comment's anchor wins over the page it's on.
    init?(page: [String], fragment: String) {
        if let id = fragment.wholeMatch(of: /issuecomment-(\d+)/).flatMap({ Int($0.1) }) {
            self = .comment(id)
            return
        }
        if let id = fragment.wholeMatch(of: /pullrequestreview-(\d+)/).flatMap({ Int($0.1) }) {
            self = .review(id)
            return
        }
        if let id = fragment.wholeMatch(of: /(?:discussion_)?r(\d+)/).flatMap({ Int($0.1) }) {
            self = .reviewComment(id)
            return
        }
        // A line's anchor, such as `R12` or `L3-R5`, follows the hash; only the file is taken.
        let fileHash = fragment.prefixMatch(of: /diff-([0-9a-f]{64})/).map { String($0.1) }
        // A range of commits, `<oid>..<oid>`, isn't one commit, so shows the whole PR's files.
        let commit = page.dropFirst().first.flatMap { $0.wholeMatch(of: /[0-9a-f]{7,40}/) }.map { String($0.0) }
        switch page.first {
        case "files", "changes":
            self = .files(commit: commit, fileHash: fileHash)
        case "commits":
            guard let commit else { return nil }
            self = .files(commit: commit, fileHash: fileHash)
        case nil:
            guard let fileHash else { return nil }
            self = .files(commit: nil, fileHash: fileHash)
        default:
            return nil
        }
    }
}

/// The URL to give the browser for a link Loupe sends there. A github.com link gets the marker
/// `via=loupe`, which GitHub ignores, so a link router that sends GitHub's PR links to Loupe can
/// tell Loupe's own apart and let them through rather than send them back. Others are unchanged.
public func browserURL(for url: URL) -> URL {
    guard ["http", "https"].contains(url.scheme?.lowercased()),
          let host = url.host()?.lowercased(), gitHubHosts.contains(host),
          var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return url }
    let query = components.percentEncodedQuery ?? ""
    guard !query.split(separator: "&").contains(Substring(browserMarker)) else { return url }
    components.percentEncodedQuery = query.isEmpty ? browserMarker : "\(query)&\(browserMarker)"
    return components.url ?? url
}

private let gitHubHosts = ["github.com", "www.github.com"]
private let browserMarker = "via=loupe"

private extension Character {
    var isASCIIDigit: Bool { isASCII && isNumber }
}
