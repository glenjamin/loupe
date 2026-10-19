import LoupeModel

extension PullRequestTab {
    /// The viewer's approval or request for changes, when that's their latest review, and how
    /// the PR's head has moved on from the commit it was given on. Commits since are counted
    /// from the PR's commits as diffed, when that diff is of the head and has the commit;
    /// otherwise a head that's moved on, force-pushed or not yet diffed, is just `.changed`.
    public var viewerVerdict: ViewerVerdict? {
        guard let review = conversation?.viewerReview, review.state.isVerdict else { return nil }
        let diffed = if case let .ready(diff) = phase { diff } else { nil as ReviewDiff? }
        let head = pullRequest.headRefOid ?? diffed?.headOid
        let since: ViewerVerdict.Since
        if review.commitOid == head {
            since = .unchanged
        } else if let diffed, diffed.headOid == head, let index = diffed.commits.firstIndex(where: { $0.oid == review.commitOid }) {
            since = .commits(diffed.commits.count - 1 - index)
        } else {
            since = .changed
        }
        return ViewerVerdict(state: review.state, commitOid: review.commitOid, submittedAt: review.submittedAt, since: since)
    }
}
