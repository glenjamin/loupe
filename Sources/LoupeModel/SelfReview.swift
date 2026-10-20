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

    /// How many of the files to review in the diff of `pullRequest`'s current head the viewer has
    /// viewed as they are now, when it's their own PR; nil when it isn't, or nothing is known of
    /// that head. A push since the diff was produced undoes it until the new diff is reviewed too.
    public func selfReview(of pullRequest: PullRequestSummary, viewer: String?) -> SelfReview? {
        guard let viewer, pullRequest.author == viewer, pullRequest.headRefOid == diffedHeadRefOid,
              !reviewablePaths.isEmpty
        else { return nil }
        return SelfReview(viewed: reviewablePaths.count { viewedStates[$0]?.isViewed == true }, total: reviewablePaths.count)
    }

    /// Whether `pullRequest` is the viewer's own and every file to review in its diff of the PR's
    /// current head is viewed as it is now, so it's ready for others to review.
    public func isSelfReviewed(_ pullRequest: PullRequestSummary, viewer: String?) -> Bool {
        selfReview(of: pullRequest, viewer: viewer)?.isComplete == true
    }
}

/// How much of their own PR the viewer has reviewed themselves: files viewed of those to review.
public struct SelfReview: Sendable, Equatable {
    public let viewed: Int
    public let total: Int

    public init(viewed: Int, total: Int) {
        self.viewed = viewed
        self.total = total
    }

    public var isComplete: Bool { viewed == total }

    public var fraction: Double { Double(viewed) / Double(total) }
}
