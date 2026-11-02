import Foundation
import LoupeModel

extension GitHubClient {
    /// The titles and states of the PRs `links` name, keyed by the links as given. A PR GitHub
    /// doesn't have or show the viewer is left out, as is a link to an issue, which GitHub links
    /// the same way.
    public func linkedPullRequests(_ links: [PullRequestLink]) async throws -> [PullRequestLink: LinkedPullRequest] {
        var found: [PullRequestLink: LinkedPullRequest] = [:]
        for start in stride(from: 0, to: links.count, by: Self.pageSize) {
            let batch = Array(links[start..<min(start + Self.pageSize, links.count)])
            let variables = Dictionary(uniqueKeysWithValues: batch.indices.map { ("u\($0)", "https://github.com/\(batch[$0].repository)/pull/\(batch[$0].number)") })
            let response: [String: LinkedNode?] = try await query(Self.linkedQuery(count: batch.count), variables: variables, allowingMissingNodes: true)
            for (index, link) in batch.enumerated() {
                if let node = response["u\(index)"] ?? nil, let title = node.title, let state = node.state {
                    found[link] = LinkedPullRequest(title: title, state: state)
                }
            }
        }
        return found
    }

    /// One aliased `resource` lookup per URL, as GraphQL has no way to look up a list of them.
    static func linkedQuery(count: Int) -> String {
        let variables = (0..<count).map { "$u\($0): URI!" }.joined(separator: ", ")
        let lookups = (0..<count).map { "u\($0): resource(url: $u\($0)) { ... on PullRequest { title state } }" }.joined(separator: "\n  ")
        return "query(\(variables)) {\n  \(lookups)\n}"
    }
}

/// An issue answers with no fields, as only a PR's are asked for.
private struct LinkedNode: Decodable {
    let title: String?
    let state: PullRequestState?
}
