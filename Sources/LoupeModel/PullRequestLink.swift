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
