import Foundation
import LoupeModel

extension GitHubClient {
    /// The titles of the PRs `links` name, keyed by the links as given. A PR GitHub doesn't have
    /// or show the viewer is left out, as is a link to an issue, which GitHub links the same way.
    public func pullRequestTitles(_ links: [PullRequestLink]) async throws -> [PullRequestLink: String] {
        var titles: [PullRequestLink: String] = [:]
        for start in stride(from: 0, to: links.count, by: Self.pageSize) {
            let batch = Array(links[start..<min(start + Self.pageSize, links.count)])
            let variables = Dictionary(uniqueKeysWithValues: batch.indices.map { ("u\($0)", "https://github.com/\(batch[$0].repository)/pull/\(batch[$0].number)") })
            let response: [String: TitleNode?] = try await query(Self.titlesQuery(count: batch.count), variables: variables, allowingMissingNodes: true)
            for (index, link) in batch.enumerated() {
                if let title = response["u\(index)"]??.title { titles[link] = title }
            }
        }
        return titles
    }

    /// One aliased `resource` lookup per URL, as GraphQL has no way to look up a list of them.
    static func titlesQuery(count: Int) -> String {
        let variables = (0..<count).map { "$u\($0): URI!" }.joined(separator: ", ")
        let lookups = (0..<count).map { "u\($0): resource(url: $u\($0)) { ... on PullRequest { title } }" }.joined(separator: "\n  ")
        return "query(\(variables)) {\n  \(lookups)\n}"
    }
}

/// An issue answers with no fields, as only a PR's are asked for.
private struct TitleNode: Decodable {
    let title: String?
}
