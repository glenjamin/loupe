/// A PR a link names, as much of it as a link's tooltip says.
public struct LinkedPullRequest: Sendable, Equatable {
    public let title: String
    public let state: PullRequestState

    public init(title: String, state: PullRequestState) {
        self.title = title
        self.state = state
    }
}
