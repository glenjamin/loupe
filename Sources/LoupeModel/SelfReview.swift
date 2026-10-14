/// How far the viewer's review of a PR's diff has got: the head the diff was produced of, the
/// files in it to review (not those hidden as vendored, lockfiles or generated), and GitHub's
/// viewed state of each file.
public struct ReviewProgress: Sendable, Equatable {
    public var diffedHeadRefOid: String
    public var reviewablePaths: [String]
    public var viewedStates: [String: FileViewedState]

    public init(diffedHeadRefOid: String, reviewablePaths: [String], viewedStates: [String: FileViewedState]) {
        self.diffedHeadRefOid = diffedHeadRefOid
        self.reviewablePaths = reviewablePaths
        self.viewedStates = viewedStates
    }

    /// Whether `pullRequest` is the viewer's own and every file to review in its diff of the PR's
    /// current head is viewed as it is now, so it's ready for others to review. A push since the
    /// diff was produced undoes it until the new diff is reviewed too.
    public func isSelfReviewed(_ pullRequest: PullRequestSummary, viewer: String?) -> Bool {
        guard let viewer, pullRequest.author == viewer, pullRequest.headRefOid == diffedHeadRefOid,
              !reviewablePaths.isEmpty
        else { return false }
        return reviewablePaths.allSatisfy { viewedStates[$0]?.isViewed == true }
    }
}
