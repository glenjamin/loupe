import Foundation
import LoupeModel
import Observation

/// The tab of a PR a link names that isn't stored, shown at once from the link alone while
/// GitHub is asked for it, and replaced in place by the PR's own tab once found. If it can't be
/// found it stays, saying why, until the viewer tries again or closes it.
@Observable
@MainActor
public final class PendingTab: Identifiable {
    /// Never a PR's id, which GitHub gives only once the PR is found.
    public let id: String
    public let link: PullRequestLink
    /// What the latest link to the PR points at, landed on once the PR's tab takes this one's
    /// place.
    var target: PullRequestLink.Target?
    /// Why the PR couldn't be opened; nil while it's being looked up.
    public internal(set) var error: String?
    /// The lookup underway or last made, for a second link to the PR to wait on.
    @ObservationIgnored var lookup: Task<Void, Never>?

    init(link: PullRequestLink) {
        self.link = link
        target = link.target
        id = "link:\(link.repository.lowercased())#\(link.number)"
    }

    /// `repo #number`, as the PR's own tab will be titled.
    public var title: String {
        tabTitle(repository: link.repository, number: link.number)
    }

    /// The PR's page on github.com.
    public var url: URL {
        gitHub.appending(path: link.repository).appending(path: "pull/\(link.number)")
    }
}

/// `repo #number`: a tab's title, short enough for the strip.
func tabTitle(repository: String, number: Int) -> String {
    let name = repository.split(separator: "/").last.map(String.init) ?? repository
    return "\(name) #\(number)"
}

private let gitHub = URL(string: "https://github.com")!
