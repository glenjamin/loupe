import Foundation

/// The `owner/name` a git remote URL points at on github.com.
struct GitHubRemote: Equatable {
    let owner: String
    let name: String

    /// Accepts `git@github.com:owner/name.git`, `ssh://git@github.com/owner/name.git` and
    /// `https://github.com/owner/name.git`, each with or without `.git`. Nil for other hosts.
    init?(url: String) {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let path: Substring
        if url.hasPrefix("git@github.com:") {
            path = url.dropFirst("git@github.com:".count)
        } else if let components = URLComponents(string: url),
                  ["https", "ssh", "git"].contains(components.scheme),
                  components.host?.lowercased() == "github.com" {
            path = Substring(components.path)
        } else {
            return nil
        }
        var parts = path.split(separator: "/")
        guard parts.count == 2 else { return nil }
        if parts[1].hasSuffix(".git") { parts[1] = parts[1].dropLast(4) }
        guard !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        owner = String(parts[0])
        name = String(parts[1])
    }

    /// GitHub owner and repo names are case-insensitive.
    func matches(_ nameWithOwner: String) -> Bool {
        "\(owner)/\(name)".lowercased() == nameWithOwner.lowercased()
    }
}

extension [Git.Remote] {
    /// The remote pointing at `nameWithOwner` on GitHub, `origin` if several do, as a fork's
    /// checkout may have the PR's repo as `upstream`.
    func matching(_ nameWithOwner: String) -> Git.Remote? {
        let matches = filter { GitHubRemote(url: $0.url)?.matches(nameWithOwner) == true }
        return matches.first { $0.name == "origin" } ?? matches.first
    }
}
