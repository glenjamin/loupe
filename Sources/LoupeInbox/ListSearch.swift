import Foundation
import LoupeModel

extension PullRequestListModel {
    /// Whether the lists are narrowed to what matches `searchText`, which has a word in it.
    public var isSearching: Bool {
        !searchWords.isEmpty
    }

    /// Whether every word searched for is in one or another of the PR's title, `owner/name`,
    /// `#number`, author, head branch or the names of those asked to review it, ignoring case
    /// and accents. Everything matches while there's no search.
    public func matchesSearch(_ pullRequest: PullRequestSummary) -> Bool {
        let fields = [
            pullRequest.title, pullRequest.repository, "#\(pullRequest.number)", pullRequest.author ?? "", pullRequest.headRefName,
        ] + (pullRequest.requestedReviewers ?? []).compactMap(\.name)
        return searchWords.allSatisfy { word in
            fields.contains { $0.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    private var searchWords: [Substring] {
        searchText.split(whereSeparator: \.isWhitespace)
    }
}
