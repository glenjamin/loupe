import Foundation
import LoupeGitHub

/// GitHub's conversations of PRs, each starting as the one captured in `probe/conversation.json`.
/// Like GitHub's GraphQL API it pages a PR's timeline with cursors at no more than the page size
/// asked for, answers a page after the first with the timeline alone, and has no node for a PR it
/// doesn't know. Its repos' people and teams are those in `probe/reviewer-candidates.json`, which
/// it pages with cursors as GitHub does; asking them to review adds them to a PR's review
/// requests, and asking anyone it doesn't know is refused, as GitHub refuses an id it can't
/// resolve. Requests are withdrawn over REST, for a PR added with its number, which leaves any
/// review the reviewer submitted and passes over anyone not asked, or refused. A PR's description can be asked for alone and replaced with `updatePullRequest`,
/// which renders it afresh. A PR's review threads can be asked for alone, replied to over
/// REST, which adds the viewer's comment, and resolved or unresolved. The viewer can hold one
/// pending review per PR, as in `probe/pending-review.json`: started with or without threads,
/// added to, submitted (which answers their review request and, once linked to the PRs' GitHub
/// with `decideReviews(on:)`, sets the PR's review decision) or deleted with its comments, which
/// until then are in the review threads marked `PENDING` and can be deleted one at a time. Tests can add comments,
/// reviews and review threads, ask for reviews or edit a description, as people do on GitHub,
/// give a PR the suggested reviewers in `probe/suggested-reviewers.json` or make asking for
/// them fail, hide the teams, as from a token without access to them, shrink the pages of people and
/// teams, refuse edits or changes to threads and reviews, as for a PR the token can't write to,
/// hold a kind of write unanswered until they release it, as over a slow network, or make every
/// request fail. Writes answer with what they made, in the shapes the app asks for. The
/// description, comments, reviews and thread comments carry GitHub's eight reaction groups;
/// tests can react as others do, and the viewer's reactions are added and taken away with
/// `addReaction` and `removeReaction`, or refused. The viewer's comments on a PR itself, with
/// `addComment`, go at the end of its timeline, or are refused. Each comment, thread comment
/// and review says whether the viewer may edit it, as only their own may be; its markdown can be
/// asked for by id (for the captured ones, which came without it, their rendering with the tags
/// taken out), and the viewer's are edited with `updatePullRequestReviewComment`,
/// `updateIssueComment` and `updatePullRequestReview`, which render them afresh, or refused.
/// Each comment says whether the viewer may delete it, as only their own may be; the viewer's
/// comments on a PR go with `deleteIssueComment`, or are refused.
actor FakeConversations {
    /// Each PR's conversation, less its timeline, in GitHub's JSON shape.
    private var nodes: [String: [String: Any]] = [:]
    /// The viewer's pending review of each PR, by PR id.
    private var pendingReviews: [String: PendingReviewState] = [:]
    private var reviewCount = 0
    /// Every review mutation received, in order.
    private(set) var reviewMutationsReceived: [ReviewMutation] = []
    /// The PRs' rows, whose review decision a submitted review sets.
    private var github: FakeGitHub?

    struct PendingReviewState {
        let id: String
        var body: String
        /// The head it was started on, which it's submitted on; nil for the PR's head then.
        var commit: String?
    }

    enum ReviewMutation: Equatable {
        case addReview(pullRequestId: String, commitId: String?, body: String?, event: String?, threads: [ThreadInput])
        case addThread(reviewId: String, ThreadInput)
        case addCommitComment(reviewId: String, commitId: String, path: String, position: Int, body: String)
        case submit(reviewId: String, event: String, body: String?)
        case delete(reviewId: String)
        case deleteComment(id: String)
    }

    struct ThreadInput: Equatable {
        let path: String
        let line: Int
        let side: String
        let body: String
        var startLine: Int? = nil
        var startSide: String? = nil
    }

    /// The kinds of write a test can hold, as over a slow network, and the conversation's first
    /// page and the threads alone, held once answered, so they land with what GitHub had when
    /// they were asked for.
    enum Gate: Hashable {
        case comment, reply, resolve, addToReview, submit, discard, deleteComment, conversationComment, edit, deleteConversationComment
        case removeReviewRequest
        case conversation, threads
    }

    /// The markdown of each comment, thread comment and review made here, by id.
    private var markdown: [String: String] = [:]
    private var commentEditsRefused = false
    /// Every edit received, in order.
    private(set) var editsReceived: [EditInput] = []
    /// The id of each comment on a PR the viewer asked to delete, in order.
    private(set) var conversationCommentDeletions: [String] = []

    struct EditInput: Equatable {
        let mutation: String
        let id: String
        let body: String
    }

    /// Kinds of request held until released.
    private var held: Set<Gate> = []
    /// The requests waiting at the gate, by kind.
    private var waiting: [Gate: [CheckedContinuation<Void, Never>]] = [:]
    private var timelines: [String: [[String: Any]]] = [:]
    private var failing = false
    private var teamsHidden = false
    private var editsRefused = false
    /// How many timeline pages have been served, first pages included.
    private(set) var pagesServed = 0
    /// The input of every `requestReviews` received, in order.
    private(set) var reviewRequestsReceived: [ReviewRequestInput] = []
    /// Every withdrawal of review requests received, in order.
    private(set) var reviewRequestRemovalsReceived: [ReviewRequestRemoval] = []
    private var reviewRequestRemovalsRefused = false
    /// The input of every `updatePullRequest` received, in order.
    private(set) var updatesReceived: [UpdateInput] = []
    /// How many pages of people or teams have been asked for, served or not.
    private(set) var candidatePagesAskedFor = 0
    private var candidatePageSize = 100
    private var users: [[String: Any]] = []
    private var teams: [[String: Any]] = []
    /// Each PR's suggested reviewers, by PR id, for those given any.
    private var suggestions: [String: [[String: Any]]] = [:]
    private var suggestionsFailing = false
    /// How many times suggested reviewers have been asked for, served or not.
    private(set) var suggestionFetches = 0
    /// How many threads and thread comments have been made here, for their ids.
    private var threadCount = 0
    private var commentCount = 0
    private var threadChangesRefused = false
    /// Each PR's id by number, for those added with one.
    private var numbers: [Int: String] = [:]
    /// Every new comment received, in order.
    private(set) var commentsReceived: [CommentInput] = []
    /// Each PR's head, by id, for those given one, which threads are made on unless said.
    private var heads: [String: String] = [:]

    struct CommentInput: Equatable {
        let repository: String
        let number: Int
        let body: String
        let commitId: String
        let path: String
        let line: Int
        let side: String
        var startLine: Int? = nil
        var startSide: String? = nil
    }

    /// Each PR's base, by id, for those given one, which a comment on a commit is placed from.
    private var bases: [String: String] = [:]
    /// The bare repo GitHub's compare and its diffs up to a commit are made from.
    private var diffRepository: URL?

    /// Says what the PR's head is, as pushing to it does.
    func setHead(_ oid: String, of id: String) {
        heads[id] = oid
    }

    /// Says what the PR's base is, as opening it on a branch does.
    func setBase(_ oid: String, of id: String) {
        bases[id] = oid
    }

    /// Diffs commits from `origin`, a bare repo holding the PRs' commits, for GitHub's compare
    /// and to place a comment on a commit by its position.
    func serveDiffs(from origin: URL) {
        diffRepository = origin
    }
    /// Every comment on a PR itself received, in order.
    private(set) var conversationCommentsReceived: [ConversationCommentInput] = []
    private var conversationCommentsRefused = false

    struct ConversationCommentInput: Equatable {
        let subjectId: String
        let body: String
    }
    /// Every reply to a thread received, in order.
    private(set) var repliesReceived: [ReplyInput] = []
    /// Every resolve or unresolve received, in order.
    private(set) var resolutionsReceived: [ResolutionInput] = []
    /// Every reaction added or taken away, in order.
    private(set) var reactionsReceived: [ReactionInput] = []
    private var reactionsRefused = false
    /// Reactions waiting to be answered while they're held.
    private var heldReactions: [CheckedContinuation<Void, Never>]?

    struct ReactionInput: Equatable {
        let subjectId: String
        let content: String
        let added: Bool
    }
    /// How many times the review threads have been asked for on their own.
    private(set) var threadFetches = 0

    struct ReplyInput: Equatable {
        let repository: String
        let number: Int
        let commentId: Int
        let body: String
    }

    struct ResolutionInput: Equatable {
        let threadId: String
        let resolved: Bool
    }

    struct ReviewRequestInput: Equatable {
        let pullRequestId: String
        let userIds: [String]
        let teamIds: [String]
        let union: Bool
    }

    struct ReviewRequestRemoval: Equatable {
        let repository: String
        let number: Int
        let reviewers: [String]
        let teamReviewers: [String]
    }

    struct UpdateInput: Equatable {
        let pullRequestId: String
        let body: String?
    }

    /// Gives the PR with `id` the probe's conversation, and with its `number` it can be
    /// commented on over REST, which names PRs by number. With `author` it's theirs rather than
    /// the probe's author.
    func add(_ id: String, number: Int? = nil, author: String? = nil) throws {
        if let number { numbers[number] = id }
        let probe = try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/conversation.json")))
        var node = try require(((probe as? [String: Any])?["data"] as? [String: Any])?["node"] as? [String: Any])
        if let author { node["author"] = ["login": author, "avatarUrl": "https://avatars.githubusercontent.com/u/151272?v=4"] }
        let timeline = try require(node["timelineItems"] as? [String: Any])
        timelines[id] = try require(timeline["nodes"] as? [[String: Any]])
        node["timelineItems"] = nil
        nodes[id] = node
        try loadPeople()
    }

    /// Adds a comment to the end of the PR's timeline, returning its id; with its `markdown`,
    /// that's what editing it starts from, and its `body`; without, its rendering with the tags
    /// taken out is.
    @discardableResult
    func comment(_ bodyHTML: String, on id: String, by login: String = "octocat", markdown: String? = nil, at date: Date = .now) -> String {
        let index = timelines[id, default: []].count
        let commentId = "IC_fake_\(index)"
        timelines[id, default: []].append([
            "__typename": "IssueComment",
            "id": commentId,
            "databaseId": 800_000 + index,
            "bodyHTML": bodyHTML,
            "body": markdown ?? bodyHTML.replacing(/<[^>]+>/, with: ""),
            "createdAt": date.formatted(.iso8601),
            "updatedAt": date.formatted(.iso8601),
            "isMinimized": false,
            "viewerCanUpdate": login == FakeGitHub.viewer,
            "viewerCanDelete": login == FakeGitHub.viewer,
            "author": ["login": login, "avatarUrl": "https://avatars.githubusercontent.com/u/583231?v=4"],
            "reactionGroups": noReactions,
        ])
        if let markdown { self.markdown[commentId] = markdown }
        return commentId
    }

    /// The REST id of the PR's comment or review with node id `id`, which github.com's links
    /// name.
    func databaseId(of id: String, on pullRequestId: String) -> Int? {
        timelines[pullRequestId]?.first { $0["id"] as? String == id }?["databaseId"] as? Int
    }

    /// Rewrites a comment in place, as a bot does that keeps one comment current; GitHub renders
    /// it as `bodyHTML` and marks it updated `at`.
    func edit(comment commentId: String, on id: String, to markdown: String, bodyHTML: String, at date: Date = .now) throws {
        var timeline = try require(timelines[id])
        let index = try require(timeline.firstIndex { $0["id"] as? String == commentId })
        timeline[index]["body"] = markdown
        timeline[index]["bodyHTML"] = bodyHTML
        timeline[index]["updatedAt"] = date.formatted(.iso8601)
        timelines[id] = timeline
        self.markdown[commentId] = markdown
    }

    /// Adds a force-push replacing head `before` with `after` to the end of the PR's timeline,
    /// as GitHub records one.
    func forcePush(from before: String, to after: String, on id: String) {
        let index = timelines[id, default: []].count
        timelines[id, default: []].append([
            "__typename": "HeadRefForcePushedEvent",
            "id": "HRFPE_fake_\(index)",
            "createdAt": Date.now.formatted(.iso8601),
            "actor": ["login": "octocat", "avatarUrl": "https://avatars.githubusercontent.com/u/583231?v=4"],
            "beforeCommit": ["oid": before],
            "afterCommit": ["oid": after],
        ])
    }

    /// The markdown of the comment, thread comment or review with `id`, as GitHub has it now.
    func markdown(of id: String) -> String? {
        if let written = markdown[id] { return written }
        if let pending = pendingReviews.values.first(where: { $0.id == id }) { return pending.body }
        return node(withId: id).flatMap { $0["bodyHTML"] as? String }.map { $0.replacing(/<[^>]+>/, with: "") }
    }

    /// Refuses edits of comments and reviews, and deletions of comments on the PR, as for a PR
    /// the token can't write to.
    func refuseCommentEdits() { commentEditsRefused = true }

    /// Reacts with `content` to the description, comment, review or thread comment with
    /// `subjectId`, as `login` does on github.com.
    func react(_ content: String, to subjectId: String, by login: String = "octocat") throws {
        try require(changeReactions(of: subjectId) { setReaction(content, added: true, by: login, in: &$0) } != nil, "Nothing to react to with id \(subjectId)")
    }

    /// The reactions to whatever has `subjectId`, as GitHub has them now.
    func reactions(to subjectId: String) -> [[String: Any]]? {
        changeReactions(of: subjectId) { _ in }
    }

    /// Refuses the viewer's reactions, as GitHub does on a locked conversation.
    func refuseReactions() { reactionsRefused = true }

    /// Keeps the viewer's reactions from being answered until `releaseReactions()`, as on a
    /// slow connection.
    func holdReactions() { heldReactions = [] }

    func releaseReactions() {
        let held = heldReactions ?? []
        heldReactions = nil
        for reaction in held { reaction.resume() }
    }

    /// Starts a review thread on the PR, as a reviewer does on github.com, in the shape of
    /// `probe/review-threads.json`, and returns its id. An outdated thread has only its
    /// original line, as GitHub keeps it; `line: nil` without that is on the whole file.
    /// A thread in the viewer's pending review can't be resolved until it's submitted. It's
    /// made on `commit`, or the PR's head if known, its original commit as GitHub keeps it.
    @discardableResult
    func startThread(
        on id: String, path: String, line: Int?, side: String = "RIGHT", startLine: Int? = nil, startSide: String? = nil, commit: String? = nil,
        outdated: Bool = false, resolved: Bool = false, pending: Bool = false, body: String, by login: String = "octocat"
    ) throws -> String {
        var node = try require(nodes[id])
        var threads = ((node["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let threadId = "PRRT_fake_\(threadCount)"
        threadCount += 1
        let current = outdated ? nil : line
        threads.append([
            "id": threadId,
            "isResolved": resolved,
            "isOutdated": outdated,
            "path": path,
            "line": current as Any? ?? NSNull(),
            "startLine": (outdated ? nil : startLine ?? line) as Any? ?? NSNull(),
            "diffSide": side,
            "startDiffSide": startLine == nil ? NSNull() : startSide ?? side,
            "originalLine": line as Any? ?? NSNull(),
            "originalStartLine": startLine as Any? ?? NSNull(),
            "subjectType": line == nil ? "FILE" : "LINE",
            "viewerCanReply": true,
            "viewerCanResolve": !resolved && !pending,
            "viewerCanUnresolve": resolved,
            "resolvedBy": resolved ? ["login": login] : NSNull(),
            "firstComment": ["nodes": [[
                "diffHunk": "@@ -1,2 +1,2 @@\n-old \(path)\n+new \(path)",
                "originalCommit": (commit ?? heads[id]).map { ["oid": $0] as Any } ?? NSNull(),
            ]]],
            "comments": ["nodes": [threadComment(body, by: login, pending: pending)]],
        ])
        node["reviewThreads"] = ["nodes": threads]
        nodes[id] = node
        return threadId
    }

    /// The PR's review threads as GitHub has them now.
    func threads(of id: String) -> [[String: Any]] {
        ((nodes[id]?["reviewThreads"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
    }

    /// Submits a review of the PR by the user with `login`, which becomes their latest and
    /// answers any request of them, as on GitHub. The viewer's is also the PR's
    /// `viewerLatestReview`, made against the PR's head `commit`.
    func review(_ state: String, by login: String, on id: String, commit: String? = nil) throws {
        let user = try self.user(login)
        var node = try require(nodes[id])
        var reviews = ((node["latestReviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        reviews.removeAll { ($0["author"] as? [String: Any])?["login"] as? String == login }
        reviews.append(["state": state, "submittedAt": Date.now.formatted(.iso8601), "author": user])
        node["latestReviews"] = ["nodes": reviews]
        if login == FakeGitHub.viewer {
            node["viewerLatestReview"] = ["state": state, "submittedAt": Date.now.formatted(.iso8601), "commit": commit.map { ["oid": $0] as Any } ?? NSNull()]
        }
        let requests = ((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        node["reviewRequests"] = ["nodes": requests.filter { ($0["requestedReviewer"] as? [String: Any])?["login"] as? String != login }]
        nodes[id] = node
    }

    /// Asks the user with `login` to review, as from github.com.
    func request(_ login: String, on id: String) throws {
        try addRequest(user(login), on: id)
    }

    func hideTeams() { teamsHidden = true }

    /// Refuses to withdraw review requests, as for a PR the token can't write to.
    func refuseReviewRequestRemovals() { reviewRequestRemovalsRefused = true }

    /// Replaces the PR's description, as its author does on github.com.
    func editBody(_ body: String, on id: String) throws {
        var node = try require(nodes[id])
        setBody(body, on: &node)
        nodes[id] = node
    }

    func body(of id: String) -> String? {
        nodes[id]?["body"] as? String
    }

    func refuseEdits() { editsRefused = true }

    /// Caps the pages of people and teams below what's asked for, so they take several.
    func limitCandidatePages(to size: Int) { candidatePageSize = size }

    func timelineCount(of id: String) -> Int {
        timelines[id]?.count ?? 0
    }

    func fail() { failing = true }
    func recover() { failing = false }

    /// Holds requests of this kind as they arrive until released: a write unanswered and not
    /// yet made, or the conversation as it was when asked for.
    func hold(_ gate: Gate) {
        held.insert(gate)
    }

    /// Lets the held requests of this kind through, and those after them.
    func release(_ gate: Gate) {
        held.remove(gate)
        for waiter in waiting.removeValue(forKey: gate) ?? [] { waiter.resume() }
    }

    /// Returns once a request of this kind is held at the gate.
    func arrival(of gate: Gate) async {
        while waiting[gate]?.isEmpty ?? true { await Task.yield() }
    }

    /// Waits while requests of this kind are held.
    private func pass(_ gate: Gate) async {
        guard held.contains(gate) else { return }
        await withCheckedContinuation { waiting[gate, default: []].append($0) }
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try require(request.url)
        try expect(url.absoluteString == "https://api.github.com/graphql")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "bearer \(FakeGitHub.validToken)")
        let data = try require(request.httpBody)
        let body = try require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let query = try require(body["query"] as? String)
        let variables = try require(body["variables"] as? [String: Any])
        if query.contains("assignableUsers(") || query.contains("teams(") { candidatePagesAskedFor += 1 }
        if failing { return (Data(), fakeResponse(url, status: 502)) }
        if query.contains("requestReviews(") { return try requestReviews(variables, url) }
        if query.contains("assignableUsers(") { return try usersPage(variables, url) }
        if query.contains("teams(") { return try teamsPage(variables, url) }
        if query.contains("updatePullRequest(") { return try updatePullRequest(variables, url) }
        if query.contains("addReaction(") || query.contains("removeReaction(") { return try await setReaction(added: query.contains("addReaction("), variables, url) }
        if query.contains("addComment(") {
            await pass(.conversationComment)
            return try addConversationComment(variables, url)
        }
        if query.contains("resolveReviewThread(") {
            await pass(.resolve)
            return try setResolved(query.contains("unresolveReviewThread("), variables, url)
        }
        if query.contains("addPullRequestReviewComment(") {
            await pass(.addToReview)
            return try await addCommitComment(variables, url)
        }
        if query.contains("addPullRequestReviewThread(") {
            await pass(.addToReview)
            return try addReviewThread(variables, url)
        }
        if query.contains("addPullRequestReview(") {
            let input = variables["input"] as? [String: Any]
            await pass(input?["event"] == nil ? .addToReview : .submit)
            return try await addReview(variables, url)
        }
        if query.contains("submitPullRequestReview(") {
            await pass(.submit)
            return try await submitReview(variables, url)
        }
        if query.contains("deletePullRequestReviewComment(") {
            await pass(.deleteComment)
            return try deleteReviewComment(variables, url)
        }
        if query.contains("deletePullRequestReview(") {
            await pass(.discard)
            return try deleteReview(variables, url)
        }
        if query.contains("PullRequestReviewComment { body }") { return try commentBody(variables, url) }
        if query.contains("deleteIssueComment(") {
            await pass(.deleteConversationComment)
            return try deleteIssueComment(variables, url)
        }
        for mutation in EditMutation.allCases where query.contains("\(mutation.rawValue)(") {
            await pass(.edit)
            return try edit(mutation, variables, url)
        }
        if query.contains("suggestedReviewers") { return try suggestedReviewers(variables, url) }
        let id = try require(variables["id"] as? String)
        guard var node = nodes[id], let timeline = timelines[id] else {
            return (try JSONSerialization.data(withJSONObject: ["data": ["node": NSNull()]]), fakeResponse(url, status: 200))
        }
        if query.contains("states: [PENDING]") {
            node["pendingReview"] = pendingReview(of: id, for: variables["viewer"])
        }
        if query.contains("reviewThreads"), !query.contains("timelineItems") {
            threadFetches += 1
            let threads = node["reviewThreads"] ?? ["nodes": []]
            var answer: [String: Any] = ["reviewThreads": threads]
            answer["pendingReview"] = node["pendingReview"]
            let data = try JSONSerialization.data(withJSONObject: ["data": ["node": answer]])
            await pass(.threads)
            return (data, fakeResponse(url, status: 200))
        }
        if !query.contains("timelineItems") {
            try expect(query.contains("PullRequest { body }"), "the only query of a PR without its timeline is for its description")
            return (try JSONSerialization.data(withJSONObject: ["data": ["node": ["body": node["body"] ?? ""]]]), fakeResponse(url, status: 200))
        }
        let first = try require(query.firstMatch(of: /timelineItems\(first: (\d+)/).flatMap { Int($0.1) })
        try expect(first <= 100, "GitHub's maximum page size")
        let start = try (variables["after"] as? String).map { try require(Int($0)) } ?? 0
        let end = min(start + first, timeline.count)
        pagesServed += 1
        let page: [String: Any] = [
            "pageInfo": ["hasNextPage": end < timeline.count, "endCursor": end > start ? String(end) as Any : NSNull()],
            "nodes": Array(timeline[start..<end]),
        ]
        if query.contains("reviewThreads") {
            node["timelineItems"] = page
        } else {
            node = ["timelineItems": page]
        }
        let answer = try JSONSerialization.data(withJSONObject: ["data": ["node": node]])
        if start == 0 { await pass(.conversation) }
        return (answer, fakeResponse(url, status: 200))
    }

    private func requestReviews(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = try require(variables["input"] as? [String: Any])
        let id = try require(input["pullRequestId"] as? String)
        let userIds = input["userIds"] as? [String] ?? []
        let teamIds = input["teamIds"] as? [String] ?? []
        reviewRequestsReceived.append(ReviewRequestInput(pullRequestId: id, userIds: userIds, teamIds: teamIds, union: input["union"] as? Bool ?? false))
        guard nodes[id] != nil else { return try refusal(unresolved: id, mutation: "requestReviews", url) }
        var asked: [[String: Any]] = []
        for userId in userIds {
            guard let user = (users + suggestedUsers).first(where: { $0["id"] as? String == userId }) else { return try refusal(unresolved: userId, mutation: "requestReviews", url) }
            asked.append(user)
        }
        for teamId in teamIds {
            guard let team = teams.first(where: { $0["id"] as? String == teamId }) else { return try refusal(unresolved: teamId, mutation: "requestReviews", url) }
            asked.append(["__typename": "Team", "id": teamId, "teamName": team["name"] ?? "", "combinedSlug": team["combinedSlug"] ?? ""])
        }
        for reviewer in asked {
            try addRequest(reviewer, on: id)
        }
        return (try JSONSerialization.data(withJSONObject: ["data": ["requestReviews": ["clientMutationId": NSNull()]]]), fakeResponse(url, status: 200))
    }

    /// `DELETE /repos/{owner}/{repo}/pulls/{number}/requested_reviewers`, naming users by login
    /// and teams by slug. Like GitHub it takes those named off the PR's review requests, passing
    /// over anyone not asked, leaves their reviews alone, and answers with the PR.
    private func removeReviewRequests(_ request: URLRequest, repository: String, number: Int, _ url: URL) throws -> (Data, HTTPURLResponse) {
        try expect(request.httpMethod == "DELETE")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "bearer \(FakeGitHub.validToken)")
        let body = try require(request.httpBody)
        let content = try require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let logins = content["reviewers"] as? [String] ?? []
        let slugs = content["team_reviewers"] as? [String] ?? []
        reviewRequestRemovalsReceived.append(ReviewRequestRemoval(repository: repository, number: number, reviewers: logins, teamReviewers: slugs))
        if failing { return (Data(), fakeResponse(url, status: 502)) }
        if reviewRequestRemovalsRefused {
            return (Data(#"{"message":"Resource not accessible by personal access token","status":"403"}"#.utf8), fakeResponse(url, status: 403))
        }
        guard let id = numbers[number], var node = nodes[id] else {
            return (Data(#"{"message":"Not Found","status":"404"}"#.utf8), fakeResponse(url, status: 404))
        }
        let requests = ((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        node["reviewRequests"] = ["nodes": requests.filter { !isNamed($0["requestedReviewer"] as? [String: Any] ?? [:], logins: logins, slugs: slugs) }]
        nodes[id] = node
        let answer: [String: Any] = ["number": number, "requested_reviewers": [], "requested_teams": []]
        return (try JSONSerialization.data(withJSONObject: answer), fakeResponse(url, status: 200))
    }

    /// A REST request: a reply to a review thread, at
    /// `/repos/{owner}/{repo}/pulls/{number}/comments/{comment_id}/replies`. Like GitHub, it
    /// takes only the REST id of a thread's first comment, as replies to replies aren't
    /// supported, and answers 201 with the new comment in `probe/review-comment-rest.json`'s
    /// shape, its `body_html` included as the `full` media type asks.
    func sendREST(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try require(request.url)
        if let match = url.path().wholeMatch(of: /\/repos\/([^\/]+\/[^\/]+)\/pulls\/(\d+)\/requested_reviewers/) {
            await pass(.removeReviewRequest)
            return try removeReviewRequests(request, repository: String(match.1), number: try require(Int(match.2)), url)
        }
        if let match = url.path().wholeMatch(of: /\/repos\/[^\/]+\/[^\/]+\/compare\/([0-9a-f]+)\.\.\.([0-9a-f]+)/) {
            return try await compare(String(match.1), String(match.2), url)
        }
        try expect(request.httpMethod == "POST")
        try expect(request.value(forHTTPHeaderField: "Authorization") == "bearer \(FakeGitHub.validToken)")
        try expect(request.value(forHTTPHeaderField: "Accept") == "application/vnd.github.full+json", "so the comment comes back rendered")
        let data = try require(request.httpBody)
        let content = try require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        if failing { return (Data(), fakeResponse(url, status: 502)) }
        if let match = url.path().wholeMatch(of: /\/repos\/([^\/]+\/[^\/]+)\/pulls\/(\d+)\/comments/) {
            await pass(.comment)
            return try newComment(content, repository: String(match.1), number: try require(Int(match.2)), url)
        }
        await pass(.reply)
        let match = try require(url.path().wholeMatch(of: /\/repos\/([^\/]+\/[^\/]+)\/pulls\/(\d+)\/comments\/(\d+)\/replies/), "Unexpected REST request: \(url.path())")
        let commentId = try require(Int(match.3))
        let body = try require(content["body"] as? String)
        repliesReceived.append(ReplyInput(repository: String(match.1), number: try require(Int(match.2)), commentId: commentId, body: body))
        if threadChangesRefused {
            return (Data(#"{"message":"Resource not accessible by personal access token","status":"403"}"#.utf8), fakeResponse(url, status: 403))
        }
        guard let (id, index) = threadStarted(by: commentId) else {
            return (Data(#"{"message":"Not Found","status":"404"}"#.utf8), fakeResponse(url, status: 404))
        }
        var threads = self.threads(of: id)
        var comments = ((threads[index]["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let comment = threadComment(body, by: FakeGitHub.viewer)
        comments.append(comment)
        threads[index]["comments"] = ["nodes": comments]
        setThreads(threads, of: id)
        var rest = try restComment(comment, body: body)
        rest["in_reply_to_id"] = commentId
        return (try JSONSerialization.data(withJSONObject: rest), fakeResponse(url, status: 201))
    }

    /// A new comment on a line, or from `start_line` to `line`, which starts a thread by the
    /// viewer at once, answered as GitHub does with the comment, or refused as GitHub refuses
    /// it while the viewer has a pending review of the PR. It's made on `commit_id`; one
    /// on a commit older than the head is outdated on the whole PR's diff, as the fake doesn't
    /// diff to tell whether GitHub could carry it onto the head's lines.
    private func newComment(_ content: [String: Any], repository: String, number: Int, _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = CommentInput(
            repository: repository, number: number, body: try require(content["body"] as? String), commitId: try require(content["commit_id"] as? String),
            path: try require(content["path"] as? String), line: try require(content["line"] as? Int), side: try require(content["side"] as? String),
            startLine: content["start_line"] as? Int, startSide: content["start_side"] as? String
        )
        commentsReceived.append(input)
        if threadChangesRefused {
            return (Data(#"{"message":"Resource not accessible by personal access token","status":"403"}"#.utf8), fakeResponse(url, status: 403))
        }
        guard let id = numbers[number] else {
            return (Data(#"{"message":"Not Found","status":"404"}"#.utf8), fakeResponse(url, status: 404))
        }
        if pendingReviews[id] != nil {
            let refusal = #"{"message":"Validation Failed","errors":["user_id can only have one pending review per pull request"],"status":"422"}"#
            return (Data(refusal.utf8), fakeResponse(url, status: 422))
        }
        try startThread(
            on: id, path: input.path, line: input.line, side: input.side, startLine: input.startLine, startSide: input.startSide, commit: input.commitId,
            outdated: heads[id].map { $0 != input.commitId } ?? false, body: input.body, by: FakeGitHub.viewer
        )
        let comment = try require(threads(of: id).last.flatMap { (($0["comments"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first })
        var rest = try restComment(comment, body: input.body)
        rest["path"] = input.path
        rest["line"] = input.line
        rest["side"] = input.side
        rest["commit_id"] = input.commitId
        rest["in_reply_to_id"] = nil
        return (try JSONSerialization.data(withJSONObject: rest), fakeResponse(url, status: 201))
    }

    /// Refuses replies and resolving, as for a PR the token can't write to.
    func refuseThreadChanges() { threadChangesRefused = true }

    /// Refuses comments on the PRs themselves, as for a locked conversation.
    func refuseConversationComments() { conversationCommentsRefused = true }

    /// A comment on the PR itself, added to the end of its timeline by the viewer and answered
    /// in `probe/add-comment.json`'s shape with it.
    private func addConversationComment(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = try require(variables["input"] as? [String: Any])
        let id = try require(input["subjectId"] as? String)
        let body = try require(input["body"] as? String)
        conversationCommentsReceived.append(ConversationCommentInput(subjectId: id, body: body))
        if conversationCommentsRefused {
            let refusal: [String: Any] = [
                "data": ["addComment": NSNull()],
                "errors": [["type": "FORBIDDEN", "path": ["addComment"], "message": "Unable to create comment because issue is locked."]],
            ]
            return (try JSONSerialization.data(withJSONObject: refusal), fakeResponse(url, status: 200))
        }
        guard timelines[id] != nil else { return try refusal(unresolved: id, mutation: "addComment", url) }
        comment("<p dir=\"auto\">\(escaped(body))</p>", on: id, by: FakeGitHub.viewer, markdown: body)
        var node = try require(timelines[id]?.last)
        node["__typename"] = nil
        let probe = try require(try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/add-comment.json"))) as? [String: Any])
        var payload = try require((probe["data"] as? [String: Any])?["addComment"] as? [String: Any])
        payload["commentEdge"] = ["node": node]
        return (try JSONSerialization.data(withJSONObject: ["data": ["addComment": payload]]), fakeResponse(url, status: 200))
    }

    private func setResolved(_ unresolve: Bool, _ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let mutation = unresolve ? "unresolveReviewThread" : "resolveReviewThread"
        let threadId = try require(variables["threadId"] as? String)
        resolutionsReceived.append(ResolutionInput(threadId: threadId, resolved: !unresolve))
        if threadChangesRefused {
            let refusal: [String: Any] = [
                "data": [mutation: NSNull()],
                "errors": [["type": "FORBIDDEN", "path": [mutation], "message": "Resource not accessible by personal access token"]],
            ]
            return (try JSONSerialization.data(withJSONObject: refusal), fakeResponse(url, status: 200))
        }
        guard let id = nodes.keys.first(where: { threads(of: $0).contains { $0["id"] as? String == threadId } }) else {
            return try refusal(unresolved: threadId, mutation: mutation, url)
        }
        var list = threads(of: id)
        let index = try require(list.firstIndex { $0["id"] as? String == threadId })
        list[index]["isResolved"] = !unresolve
        list[index]["viewerCanResolve"] = unresolve
        list[index]["viewerCanUnresolve"] = !unresolve
        list[index]["resolvedBy"] = unresolve ? NSNull() as Any : ["login": FakeGitHub.viewer]
        setThreads(list, of: id)
        let payload: [String: Any] = [mutation: ["thread": ["id": threadId, "isResolved": !unresolve]]]
        return (try JSONSerialization.data(withJSONObject: ["data": payload]), fakeResponse(url, status: 200))
    }

    /// Lets a submitted review set the review decision of its PR on `github`, as GitHub does.
    func decideReviews(on github: FakeGitHub) { self.github = github }

    /// Starts the viewer's pending review of the PR, as on github.com, holding a thread with
    /// `body` on `line` of `path`, with `summary` saved as its body. Returns the review's id.
    @discardableResult
    func startPendingReview(on id: String, path: String, line: Int, body: String, summary: String = "") throws -> String {
        let reviewId = newReviewId()
        pendingReviews[id] = PendingReviewState(id: reviewId, body: summary)
        try startThread(on: id, path: path, line: line, pending: true, body: body, by: FakeGitHub.viewer)
        return reviewId
    }

    /// Replies to the thread into the viewer's pending review, as on github.com, starting the
    /// review if they have none.
    func replyInPendingReview(to threadId: String, on id: String, body: String) throws {
        if pendingReviews[id] == nil { pendingReviews[id] = PendingReviewState(id: newReviewId(), body: "") }
        var list = threads(of: id)
        let index = try require(list.firstIndex { $0["id"] as? String == threadId })
        list[index]["comments"] = ["nodes": comments(of: list[index]) + [threadComment(body, by: FakeGitHub.viewer, pending: true)]]
        setThreads(list, of: id)
    }

    /// Discards the viewer's pending review of the PR, as on github.com.
    func discardPendingReview(on id: String) {
        removePendingReview(of: id)
    }

    /// The viewer's pending review of the PR, if they have one.
    func pendingReviewId(of id: String) -> String? {
        pendingReviews[id]?.id
    }

    /// The `pendingReview` connection: only the viewer sees their pending review, and a filter
    /// by someone else's login finds none.
    private func pendingReview(of id: String, for viewer: Any?) -> [String: Any] {
        guard let review = pendingReviews[id], viewer is NSNull || viewer == nil || viewer as? String == FakeGitHub.viewer else { return ["nodes": []] }
        return ["nodes": [["id": review.id, "body": review.body, "comments": ["totalCount": pendingComments(of: id)]]]]
    }

    /// Drops the viewer's pending review of the PR with its comments, and with them any thread
    /// it started.
    private func removePendingReview(of id: String) {
        pendingReviews[id] = nil
        setThreads(threads(of: id).compactMap { thread in
            var thread = thread
            let comments = (((thread["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []).filter { $0["state"] as? String != "PENDING" }
            guard !comments.isEmpty else { return nil }
            thread["comments"] = ["nodes": comments]
            return thread
        }, of: id)
    }

    private func pendingComments(of id: String) -> Int {
        threads(of: id).reduce(0) { count, thread in
            count + (((thread["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []).count { $0["state"] as? String == "PENDING" }
        }
    }

    private func addReview(_ variables: [String: Any], _ url: URL) async throws -> (Data, HTTPURLResponse) {
        let input = try require(variables["input"] as? [String: Any])
        let id = try require(input["pullRequestId"] as? String)
        let threads = try (input["threads"] as? [[String: Any]] ?? []).map(threadInput)
        let event = input["event"] as? String
        let body = input["body"] as? String
        reviewMutationsReceived.append(.addReview(pullRequestId: id, commitId: input["commitOID"] as? String, body: body, event: event, threads: threads))
        if let refusal = try refusalOfReviewChanges("addPullRequestReview", url) { return refusal }
        guard nodes[id] != nil else { return try refusal(unresolved: id, mutation: "addPullRequestReview", url) }
        if let event, let refusal = try refusalOfOwnVerdict(event, on: id, "addPullRequestReview", url) { return refusal }
        if pendingReviews[id] != nil {
            return try unprocessable("addPullRequestReview", "User can only have one pending review per pull request", url)
        }
        if let event, event != "APPROVE", (body ?? "").isEmpty, threads.isEmpty {
            return try unprocessable("addPullRequestReview", "Review body is required for \(event)", url)
        }
        let reviewId = newReviewId()
        var comments: [[String: Any]] = []
        for thread in threads {
            let threadId = try startThread(
            on: id, path: thread.path, line: thread.line, side: thread.side, startLine: thread.startLine, startSide: thread.startSide,
            commit: input["commitOID"] as? String, pending: event == nil, body: thread.body, by: FakeGitHub.viewer
        )
            comments += self.threads(of: id).filter { $0["id"] as? String == threadId }.flatMap { self.comments(of: $0) }
        }
        let state: String
        let commit = input["commitOID"] as? String
        if let event {
            state = try await recordReview(event, body: body ?? "", on: id, commit: commit)
        } else {
            state = "PENDING"
            pendingReviews[id] = PendingReviewState(id: reviewId, body: body ?? "", commit: commit)
        }
        let payload: [String: Any] = ["addPullRequestReview": ["pullRequestReview": try postedReview(reviewId, state: state, body: body ?? "", comments: comments)]]
        return (try JSONSerialization.data(withJSONObject: ["data": payload]), fakeResponse(url, status: 200))
    }

    private func addReviewThread(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = try require(variables["input"] as? [String: Any])
        let reviewId = try require(input["pullRequestReviewId"] as? String)
        let thread = try threadInput(input)
        reviewMutationsReceived.append(.addThread(reviewId: reviewId, thread))
        if let refusal = try refusalOfReviewChanges("addPullRequestReviewThread", url) { return refusal }
        guard let id = pullRequest(withPendingReview: reviewId) else { return try refusal(unresolved: reviewId, mutation: "addPullRequestReviewThread", url) }
        let threadId = try startThread(
            on: id, path: thread.path, line: thread.line, side: thread.side, startLine: thread.startLine, startSide: thread.startSide,
            commit: pendingReviews[id]?.commit, pending: true, body: thread.body, by: FakeGitHub.viewer
        )
        let comments = threads(of: id).filter { $0["id"] as? String == threadId }.flatMap { self.comments(of: $0) }
        let probe = try require(try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/add-review-thread.json"))) as? [String: Any])
        var payload = try require((probe["data"] as? [String: Any])?["addPullRequestReviewThread"] as? [String: Any])
        var posted = try require(payload["thread"] as? [String: Any])
        posted["id"] = threadId
        posted["comments"] = ["nodes": comments]
        payload["thread"] = posted
        return (try JSONSerialization.data(withJSONObject: ["data": ["addPullRequestReviewThread": payload]]), fakeResponse(url, status: 200))
    }

    /// A comment on a commit into the viewer's pending review, placed as GitHub places it: on the
    /// line at `position` in the diff from the PR's base to that commit, outdated on the head
    /// unless it's the head.
    private func addCommitComment(_ variables: [String: Any], _ url: URL) async throws -> (Data, HTTPURLResponse) {
        let input = try require(variables["input"] as? [String: Any])
        let reviewId = try require(input["pullRequestReviewId"] as? String)
        let commit = try require(input["commitOID"] as? String)
        let path = try require(input["path"] as? String)
        let position = try require(input["position"] as? Int)
        let body = try require(input["body"] as? String)
        reviewMutationsReceived.append(.addCommitComment(reviewId: reviewId, commitId: commit, path: path, position: position, body: body))
        if let refusal = try refusalOfReviewChanges("addPullRequestReviewComment", url) { return refusal }
        guard let id = pullRequest(withPendingReview: reviewId) else { return try refusal(unresolved: reviewId, mutation: "addPullRequestReviewComment", url) }
        let base = try require(bases[id], "the fake places a comment on a commit from the PR's base")
        guard let (line, side) = row(atPosition: position, inPatch: try await patch(of: path, from: base, to: commit)) else {
            return try unprocessable("addPullRequestReviewComment", "Pull request review thread position is invalid", url)
        }
        let threadId = try startThread(
            on: id, path: path, line: line, side: side, commit: commit, outdated: heads[id] != commit, pending: true, body: body, by: FakeGitHub.viewer
        )
        let comment = try require(threads(of: id).first { $0["id"] as? String == threadId }.flatMap { comments(of: $0).first })
        return (try JSONSerialization.data(withJSONObject: ["data": ["addPullRequestReviewComment": ["comment": comment]]]), fakeResponse(url, status: 200))
    }

    /// GitHub's compare of two commits: each file changed from their merge base to `head`, with
    /// its patch from the first hunk header on.
    private func compare(_ base: String, _ head: String, _ url: URL) async throws -> (Data, HTTPURLResponse) {
        let repository = try require(diffRepository, "the fake compares commits once it's serving diffs")
        let paths = try await runGit(["diff", "--name-only", "\(base)...\(head)"], in: repository).split(separator: "\n").map(String.init)
        var files: [[String: Any]] = []
        for path in paths { files.append(["filename": path, "patch": try await patch(of: path, from: base, to: head)]) }
        return (try JSONSerialization.data(withJSONObject: ["files": files]), fakeResponse(url, status: 200))
    }

    private func patch(of path: String, from base: String, to head: String) async throws -> String {
        let repository = try require(diffRepository, "the fake diffs commits once it's serving diffs")
        let diff = try await runGit(["diff", "\(base)...\(head)", "--", path], in: repository)
        return diff.range(of: "@@").map { String(diff[$0.lowerBound...]) } ?? ""
    }

    private func submitReview(_ variables: [String: Any], _ url: URL) async throws -> (Data, HTTPURLResponse) {
        let input = try require(variables["input"] as? [String: Any])
        let reviewId = try require(input["pullRequestReviewId"] as? String)
        let event = try require(input["event"] as? String)
        let body = input["body"] as? String
        reviewMutationsReceived.append(.submit(reviewId: reviewId, event: event, body: body))
        if let refusal = try refusalOfReviewChanges("submitPullRequestReview", url) { return refusal }
        guard let id = pullRequest(withPendingReview: reviewId) else { return try refusal(unresolved: reviewId, mutation: "submitPullRequestReview", url) }
        if let refusal = try refusalOfOwnVerdict(event, on: id, "submitPullRequestReview", url) { return refusal }
        if event != "APPROVE", (body ?? "").isEmpty, pendingComments(of: id) == 0 {
            return try unprocessable("submitPullRequestReview", "Review body is required for \(event)", url)
        }
        let commit = pendingReviews[id]?.commit
        pendingReviews[id] = nil
        setThreads(threads(of: id).map { thread in
            var thread = thread
            let comments = ((thread["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            // A thread the review started can be resolved once it's submitted.
            if comments.first?["state"] as? String == "PENDING" { thread["viewerCanResolve"] = true }
            thread["comments"] = ["nodes": comments.map { $0.merging(["state": "SUBMITTED"]) { $1 } }]
            return thread
        }, of: id)
        let state = try await recordReview(event, body: body ?? "", on: id, as: reviewId, commit: commit)
        let payload: [String: Any] = ["submitPullRequestReview": ["pullRequestReview": try postedReview(reviewId, state: state, body: body ?? "", comments: [])]]
        return (try JSONSerialization.data(withJSONObject: ["data": payload]), fakeResponse(url, status: 200))
    }

    private func deleteReview(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = try require(variables["input"] as? [String: Any])
        let reviewId = try require(input["pullRequestReviewId"] as? String)
        reviewMutationsReceived.append(.delete(reviewId: reviewId))
        if let refusal = try refusalOfReviewChanges("deletePullRequestReview", url) { return refusal }
        guard let id = pullRequest(withPendingReview: reviewId) else { return try refusal(unresolved: reviewId, mutation: "deletePullRequestReview", url) }
        removePendingReview(of: id)
        return (try JSONSerialization.data(withJSONObject: ["data": ["deletePullRequestReview": ["pullRequestReview": ["id": reviewId]]]]), fakeResponse(url, status: 200))
    }

    /// Deletes a comment wherever it is, and its thread once it has none; a pending review left
    /// with no comments stays, as GitHub keeps it. Answers in `probe/delete-review-comment.json`'s
    /// shape.
    private func deleteReviewComment(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = try require(variables["input"] as? [String: Any])
        let commentId = try require(input["id"] as? String)
        reviewMutationsReceived.append(.deleteComment(id: commentId))
        if let refusal = try refusalOfReviewChanges("deletePullRequestReviewComment", url) { return refusal }
        guard let id = nodes.keys.first(where: { threads(of: $0).contains { comments(of: $0).contains { $0["id"] as? String == commentId } } }) else {
            return try refusal(unresolved: commentId, mutation: "deletePullRequestReviewComment", url)
        }
        guard node(withId: commentId)?["viewerCanDelete"] as? Bool == true else {
            return try forbidden("deletePullRequestReviewComment", "\(FakeGitHub.viewer) does not have the correct permissions to execute `DeletePullRequestReviewComment`", url)
        }
        removeFromTimelines(commentId)
        setThreads(threads(of: id).compactMap { thread in
            var thread = thread
            let comments = comments(of: thread).filter { $0["id"] as? String != commentId }
            guard !comments.isEmpty else { return nil }
            thread["comments"] = ["nodes": comments]
            return thread
        }, of: id)
        let probe = try require(try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/delete-review-comment.json"))) as? [String: Any])
        var payload = try require((probe["data"] as? [String: Any])?["deletePullRequestReviewComment"] as? [String: Any])
        var review = try require(payload["pullRequestReview"] as? [String: Any])
        if let pending = pendingReviews[id] { review["id"] = pending.id }
        payload["pullRequestReview"] = review
        return (try JSONSerialization.data(withJSONObject: ["data": ["deletePullRequestReviewComment": payload]]), fakeResponse(url, status: 200))
    }

    /// The viewer's submitted review, on `commit` or else the PR's head as the PR's rows have
    /// it: their latest, in the timeline, among the reviews the rows are checked for, and the
    /// PR's review decision where it decides one. Returns its state.
    @discardableResult
    private func recordReview(_ event: String, body: String, on id: String, as reviewId: String? = nil, commit: String? = nil) async throws -> String {
        let state = ["APPROVE": "APPROVED", "REQUEST_CHANGES": "CHANGES_REQUESTED"][event] ?? "COMMENTED"
        var head = commit
        if head == nil, let github { head = try await github.head(of: id) }
        try review(state, by: FakeGitHub.viewer, on: id, commit: head)
        try await github?.review(id, state, commit: head)
        let index = timelines[id, default: []].count
        let submittedId = reviewId ?? "PRR_fake_timeline_\(index)"
        timelines[id, default: []].append([
            "__typename": "PullRequestReview",
            "id": submittedId,
            "state": state,
            "bodyHTML": body.isEmpty ? "" : "<p dir=\"auto\">\(escaped(body))</p>",
            "createdAt": Date.now.formatted(.iso8601),
            "submittedAt": Date.now.formatted(.iso8601),
            "viewerCanUpdate": true,
            "author": ["login": FakeGitHub.viewer, "avatarUrl": "https://avatars.githubusercontent.com/u/151272?v=4"],
            "comments": ["nodes": []],
            "reactionGroups": noReactions,
        ])
        markdown[submittedId] = body
        guard let github, state != "COMMENTED" else { return state }
        try await github.edit(id) { $0.reviewDecision = state }
        return state
    }

    /// A review by the viewer in `probe/submit-review.json`'s shape, as the `PostedReview`
    /// fragment asks for it.
    private func postedReview(_ id: String, state: String, body: String, comments: [[String: Any]]) throws -> [String: Any] {
        let probe = try require(try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/submit-review.json"))) as? [String: Any])
        var review = try require(((probe["data"] as? [String: Any])?["submitPullRequestReview"] as? [String: Any])?["pullRequestReview"] as? [String: Any])
        review["id"] = id
        review["state"] = state
        review["bodyHTML"] = body.isEmpty ? "" : "<p dir=\"auto\">\(escaped(body))</p>"
        review["createdAt"] = Date.now.formatted(.iso8601)
        review["submittedAt"] = state == "PENDING" ? NSNull() as Any : Date.now.formatted(.iso8601)
        review["comments"] = ["nodes": comments]
        return review
    }

    /// The thread comment in REST's shape, as `probe/review-comment-rest.json` has it, with
    /// its markdown as written.
    private func restComment(_ comment: [String: Any], body: String) throws -> [String: Any] {
        var rest = try require(try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/review-comment-rest.json"))) as? [String: Any])
        let author = comment["author"] as? [String: Any]
        rest["id"] = comment["databaseId"]
        rest["node_id"] = comment["id"]
        rest["body"] = body
        rest["body_html"] = comment["bodyHTML"]
        rest["created_at"] = comment["createdAt"]
        rest["user"] = ["login": author?["login"] ?? FakeGitHub.viewer, "avatar_url": author?["avatarUrl"] ?? NSNull()]
        return rest
    }

    private func pullRequest(withPendingReview reviewId: String) -> String? {
        pendingReviews.first { $0.value.id == reviewId }?.key
    }

    private func newReviewId() -> String {
        reviewCount += 1
        return "PRR_fake_\(reviewCount)"
    }

    private func threadInput(_ input: [String: Any]) throws -> ThreadInput {
        ThreadInput(
            path: try require(input["path"] as? String), line: try require(input["line"] as? Int),
            side: try require(input["side"] as? String), body: try require(input["body"] as? String),
            startLine: input["startLine"] as? Int, startSide: input["startSide"] as? String
        )
    }

    private func refusalOfReviewChanges(_ mutation: String, _ url: URL) throws -> (Data, HTTPURLResponse)? {
        guard threadChangesRefused else { return nil }
        let refusal: [String: Any] = [
            "data": [mutation: NSNull()],
            "errors": [["type": "FORBIDDEN", "path": [mutation], "message": "Resource not accessible by personal access token"]],
        ]
        return (try JSONSerialization.data(withJSONObject: refusal), fakeResponse(url, status: 200))
    }

    /// GitHub's refusal to let a PR's author approve it or ask changes of it.
    private func refusalOfOwnVerdict(_ event: String, on id: String, _ mutation: String, _ url: URL) throws -> (Data, HTTPURLResponse)? {
        guard ((nodes[id]?["author"] as? [String: Any])?["login"] as? String) == FakeGitHub.viewer else { return nil }
        switch event {
        case "APPROVE": return try unprocessable(mutation, "Can not approve your own pull request", url)
        case "REQUEST_CHANGES": return try unprocessable(mutation, "Can not request changes on your own pull request", url)
        default: return nil
        }
    }

    /// GitHub's shape for a mutation it won't carry out as asked.
    private func unprocessable(_ mutation: String, _ message: String, _ url: URL) throws -> (Data, HTTPURLResponse) {
        let body: [String: Any] = [
            "data": [mutation: NSNull()],
            "errors": [["type": "UNPROCESSABLE", "path": [mutation], "locations": [["line": 2, "column": 3]], "message": message]],
        ]
        return (try JSONSerialization.data(withJSONObject: body), fakeResponse(url, status: 200))
    }

    /// The PR and index of the thread whose first comment has REST id `commentId`.
    private func threadStarted(by commentId: Int) -> (String, Int)? {
        for id in nodes.keys {
            if let index = threads(of: id).firstIndex(where: { thread in
                (((thread["comments"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["databaseId"] as? Int) == commentId
            }) {
                return (id, index)
            }
        }
        return nil
    }

    private func comments(of thread: [String: Any]) -> [[String: Any]] {
        ((thread["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
    }

    private func setThreads(_ threads: [[String: Any]], of id: String) {
        nodes[id]?["reviewThreads"] = ["nodes": threads]
    }

    private func updatePullRequest(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = try require(variables["input"] as? [String: Any])
        let id = try require(input["pullRequestId"] as? String)
        let body = input["body"] as? String
        updatesReceived.append(UpdateInput(pullRequestId: id, body: body))
        guard var node = nodes[id] else { return try refusal(unresolved: id, mutation: "updatePullRequest", url) }
        if editsRefused {
            let refusal: [String: Any] = [
                "data": ["updatePullRequest": NSNull()],
                "errors": [["type": "FORBIDDEN", "path": ["updatePullRequest"], "message": "Resource not accessible by personal access token"]],
            ]
            return (try JSONSerialization.data(withJSONObject: refusal), fakeResponse(url, status: 200))
        }
        if let body { setBody(body, on: &node) }
        nodes[id] = node
        return (try JSONSerialization.data(withJSONObject: ["data": ["updatePullRequest": ["pullRequest": ["id": id]]]]), fakeResponse(url, status: 200))
    }

    /// Gives the PR with `id` the suggested reviewers in `probe/suggested-reviewers.json`; PRs
    /// otherwise have none, as GitHub has for code nobody else has touched lately.
    func suggestReviewers(on id: String) throws {
        let probe = try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/suggested-reviewers.json")))
        let node = try require(((probe as? [String: Any])?["data"] as? [String: Any])?["node"] as? [String: Any])
        suggestions[id] = try require(node["suggestedReviewers"] as? [[String: Any]])
    }

    /// Everyone suggested on any PR, shaped as the conversation's `Reviewer` fragment returns
    /// them, as they can be asked even when they aren't among the repo's candidates.
    private var suggestedUsers: [[String: Any]] {
        suggestions.values.joined().compactMap { ($0["reviewer"] as? [String: Any])?.merging(["__typename": "User"]) { $1 } }
    }

    /// Makes asking for suggested reviewers fail, and only that.
    func failSuggestions() { suggestionsFailing = true }

    private func suggestedReviewers(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        suggestionFetches += 1
        if suggestionsFailing { return (Data(), fakeResponse(url, status: 502)) }
        let id = try require(variables["id"] as? String)
        guard nodes[id] != nil else {
            return (try JSONSerialization.data(withJSONObject: ["data": ["node": NSNull()]]), fakeResponse(url, status: 200))
        }
        let node: [String: Any] = ["suggestedReviewers": suggestions[id] ?? []]
        return (try JSONSerialization.data(withJSONObject: ["data": ["node": node]]), fakeResponse(url, status: 200))
    }

    private func usersPage(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let page = try self.page(of: users.map { $0.filter { $0.key != "__typename" } }, variables)
        let repository: [String: Any] = ["assignableUsers": page]
        return (try JSONSerialization.data(withJSONObject: ["data": ["repository": repository]]), fakeResponse(url, status: 200))
    }

    private func teamsPage(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        if teamsHidden {
            let body: [String: Any] = [
                "data": ["repository": ["owner": ["teams": NSNull()]]],
                "errors": [["type": "FORBIDDEN", "path": ["repository", "owner", "teams"], "message": "Resource not accessible by personal access token"]],
            ]
            return (try JSONSerialization.data(withJSONObject: body), fakeResponse(url, status: 200))
        }
        let repository: [String: Any] = ["owner": ["teams": try page(of: teams, variables)]]
        return (try JSONSerialization.data(withJSONObject: ["data": ["repository": repository]]), fakeResponse(url, status: 200))
    }

    /// A connection's page of `nodes`: from the `after` cursor, at most `first` of them.
    private func page(of nodes: [[String: Any]], _ variables: [String: Any]) throws -> [String: Any] {
        let first = try require(variables["first"] as? Int)
        try expect(first <= 100, "GitHub's maximum page size")
        let start = try (variables["after"] as? String).map { try require(Int($0)) } ?? 0
        let end = min(start + min(first, candidatePageSize), nodes.count)
        return [
            "pageInfo": ["hasNextPage": end < nodes.count, "endCursor": end > start ? String(end) as Any : NSNull()],
            "nodes": Array(nodes[start..<end]),
        ]
    }

    /// GitHub keeps one request per reviewer, so asking again leaves the one there.
    private func addRequest(_ reviewer: [String: Any], on id: String) throws {
        var node = try require(nodes[id])
        var requests = ((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let reviewerId = reviewer["id"] as? String
        if !requests.contains(where: { ($0["requestedReviewer"] as? [String: Any])?["id"] as? String == reviewerId }) {
            requests.append(["requestedReviewer": reviewer])
        }
        node["reviewRequests"] = ["nodes": requests]
        nodes[id] = node
    }

    /// Whether a requested reviewer is a user among `logins` or a team among `slugs`.
    private func isNamed(_ reviewer: [String: Any], logins: [String], slugs: [String]) -> Bool {
        if reviewer["__typename"] as? String == "Team" {
            let slug = (reviewer["combinedSlug"] as? String)?.split(separator: "/").last.map(String.init)
            return slug.map(slugs.contains) ?? false
        }
        return logins.contains { $0 == reviewer["login"] as? String }
    }

    /// The user with `login`, shaped as the conversation query's `Reviewer` fragment returns them.
    private func user(_ login: String) throws -> [String: Any] {
        try require(users.first { $0["login"] as? String == login })
    }

    private func loadPeople() throws {
        guard users.isEmpty else { return }
        let probe = try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/reviewer-candidates.json")))
        let repository = try require(((probe as? [String: Any])?["data"] as? [String: Any])?["repository"] as? [String: Any])
        let assignable = try require((repository["assignableUsers"] as? [String: Any])?["nodes"] as? [[String: Any]])
        users = assignable.map { $0.merging(["__typename": "User"]) { $1 } }
        teams = try require(((repository["owner"] as? [String: Any])?["teams"] as? [String: Any])?["nodes"] as? [[String: Any]])
    }

    /// A new thread comment in the review threads query's shape, with GitHub's rendering of
    /// `body` as one paragraph and the next REST id.
    private func threadComment(_ body: String, by login: String, pending: Bool = false) -> [String: Any] {
        commentCount += 1
        let id = "PRRC_fake_\(commentCount)"
        markdown[id] = body
        return [
            "id": id,
            "databaseId": 900_000 + commentCount,
            "bodyHTML": "<p dir=\"auto\">\(escaped(body))</p>",
            "createdAt": Date.now.formatted(.iso8601),
            "isMinimized": false,
            "minimizedReason": NSNull(),
            "state": pending ? "PENDING" : "SUBMITTED",
            "viewerCanUpdate": login == FakeGitHub.viewer,
            "viewerCanDelete": login == FakeGitHub.viewer,
            "author": ["login": login, "avatarUrl": "https://avatars.githubusercontent.com/u/583231?v=4"],
            "reactionGroups": noReactions,
        ]
    }

    /// The three edits, by mutation name, each taking its own kind of thing.
    enum EditMutation: String, CaseIterable {
        case reviewComment = "updatePullRequestReviewComment"
        case issueComment = "updateIssueComment"
        case review = "updatePullRequestReview"

        /// The input's field naming what's edited.
        var idField: String {
            switch self {
            case .reviewComment: "pullRequestReviewCommentId"
            case .issueComment: "id"
            case .review: "pullRequestReviewId"
            }
        }

        /// The payload's field holding what was edited, and the probe answering in its shape.
        var payloadField: String {
            switch self {
            case .reviewComment: "pullRequestReviewComment"
            case .issueComment: "issueComment"
            case .review: "pullRequestReview"
            }
        }

        var probe: String {
            switch self {
            case .reviewComment: "probe/edit-review-comment.json"
            case .issueComment: "probe/edit-issue-comment.json"
            case .review: "probe/edit-review.json"
            }
        }
    }

    /// The markdown of a comment or review asked for by id, in `probe/edit-comment-body.json`'s
    /// shape; an id GitHub doesn't know has no node.
    private func commentBody(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let id = try require(variables["id"] as? String)
        let node: Any = markdown(of: id).map { ["body": $0] } ?? NSNull()
        return (try JSONSerialization.data(withJSONObject: ["data": ["node": node]]), fakeResponse(url, status: 200))
    }

    /// The viewer's edit of a comment's or review's body, which GitHub renders afresh wherever
    /// it shows, answered in the shape of the mutation's probe. Someone else's, or the wrong
    /// mutation for what the id names, is refused, as GitHub refuses them.
    private func edit(_ mutation: EditMutation, _ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = try require(variables["input"] as? [String: Any])
        let id = try require(input[mutation.idField] as? String)
        let body = try require(input["body"] as? String)
        editsReceived.append(EditInput(mutation: mutation.rawValue, id: id, body: body))
        if commentEditsRefused { return try forbidden(mutation.rawValue, "Resource not accessible by personal access token", url) }
        let pendingReview = pendingReviews.first { $0.value.id == id }?.key
        let node = node(withId: id)
        guard pendingReview != nil || node != nil else { return try refusal(unresolved: id, mutation: mutation.rawValue, url) }
        guard pendingReview != nil || (node?["viewerCanUpdate"] as? Bool == true && editMutation(for: id) == mutation) else {
            return try forbidden(mutation.rawValue, "\(FakeGitHub.viewer) does not have the correct permissions to execute `\(mutation.rawValue)`", url)
        }
        let bodyHTML = rendered(body)
        markdown[id] = body
        if let pendingReview { pendingReviews[pendingReview]?.body = body }
        setBodyHTML(bodyHTML, of: id)
        for (pullRequest, timeline) in timelines {
            timelines[pullRequest] = timeline.map { $0["id"] as? String == id && $0["body"] != nil ? $0.merging(["body": body]) { $1 } : $0 }
        }
        let probe = try require(try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: mutation.probe))) as? [String: Any])
        var payload = try require((probe["data"] as? [String: Any])?[mutation.rawValue] as? [String: Any])
        var edited = try require(payload[mutation.payloadField] as? [String: Any])
        edited["id"] = id
        edited["bodyHTML"] = bodyHTML
        payload[mutation.payloadField] = edited
        return (try JSONSerialization.data(withJSONObject: ["data": [mutation.rawValue: payload]]), fakeResponse(url, status: 200))
    }

    /// The comment, thread comment or review with `id`, wherever it is.
    private func node(withId id: String) -> [String: Any]? {
        for pullRequest in nodes.keys {
            for thread in threads(of: pullRequest) {
                if let comment = comments(of: thread).first(where: { $0["id"] as? String == id }) { return comment }
            }
        }
        return timelines.values.lazy.compactMap { $0.first { $0["id"] as? String == id } }.first
    }

    /// The mutation that edits what `id` names.
    private func editMutation(for id: String) -> EditMutation? {
        guard let node = node(withId: id) else { return nil }
        switch node["__typename"] as? String {
        case "IssueComment": return .issueComment
        case "PullRequestReview": return .review
        default: return .reviewComment
        }
    }

    /// Gives what `id` names a new rendering, in its thread and wherever the timeline shows it.
    private func setBodyHTML(_ bodyHTML: String, of id: String) {
        for pullRequest in nodes.keys {
            setThreads(threads(of: pullRequest).map { thread in
                var thread = thread
                thread["comments"] = ["nodes": comments(of: thread).map { $0["id"] as? String == id ? $0.merging(["bodyHTML": bodyHTML]) { $1 } : $0 }]
                return thread
            }, of: pullRequest)
        }
        for (pullRequest, timeline) in timelines {
            timelines[pullRequest] = timeline.map { item in
                var item = item
                if item["id"] as? String == id { item["bodyHTML"] = bodyHTML }
                if let reviewComments = (item["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] {
                    item["comments"] = ["nodes": reviewComments.map { $0["id"] as? String == id ? $0.merging(["bodyHTML": bodyHTML]) { $1 } : $0 }]
                }
                return item
            }
        }
    }

    /// Deletes the viewer's comment on a PR, answered in `probe/delete-issue-comment.json`'s
    /// shape; someone else's is refused, as GitHub refuses it.
    private func deleteIssueComment(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = try require(variables["input"] as? [String: Any])
        let id = try require(input["id"] as? String)
        conversationCommentDeletions.append(id)
        if commentEditsRefused { return try forbidden("deleteIssueComment", "Resource not accessible by personal access token", url) }
        guard let node = node(withId: id), node["__typename"] as? String == "IssueComment" else { return try refusal(unresolved: id, mutation: "deleteIssueComment", url) }
        guard node["viewerCanDelete"] as? Bool == true else {
            return try forbidden("deleteIssueComment", "\(FakeGitHub.viewer) does not have the correct permissions to execute `DeleteIssueComment`", url)
        }
        removeFromTimelines(id)
        let probe = try Data(contentsOf: projectRoot.appending(path: "probe/delete-issue-comment.json"))
        return (probe, fakeResponse(url, status: 200))
    }

    /// Takes what `id` names out of every timeline, and out of the review that holds it.
    private func removeFromTimelines(_ id: String) {
        for (pullRequest, timeline) in timelines {
            timelines[pullRequest] = timeline.filter { $0["id"] as? String != id }.map { item in
                var item = item
                if let reviewComments = (item["comments"] as? [String: Any])?["nodes"] as? [[String: Any]] {
                    item["comments"] = ["nodes": reviewComments.filter { $0["id"] as? String != id }]
                }
                return item
            }
        }
    }

    private func forbidden(_ mutation: String, _ message: String, _ url: URL) throws -> (Data, HTTPURLResponse) {
        let refusal: [String: Any] = [
            "data": [mutation: NSNull()],
            "errors": [["type": "FORBIDDEN", "path": [mutation], "message": message]],
        ]
        return (try JSONSerialization.data(withJSONObject: refusal), fakeResponse(url, status: 200))
    }

    /// The viewer's reaction, added or taken away as GitHub does: asking for what's already so
    /// changes nothing. Answers in `probe/add-reaction.json`'s shape with the subject's groups.
    private func setReaction(added: Bool, _ variables: [String: Any], _ url: URL) async throws -> (Data, HTTPURLResponse) {
        let mutation = added ? "addReaction" : "removeReaction"
        let subjectId = try require(variables["subjectId"] as? String)
        let content = try require(variables["content"] as? String)
        reactionsReceived.append(ReactionInput(subjectId: subjectId, content: content, added: added))
        if heldReactions != nil { await withCheckedContinuation { heldReactions?.append($0) } }
        if reactionsRefused {
            let refusal: [String: Any] = [
                "data": [mutation: NSNull()],
                "errors": [["type": "FORBIDDEN", "path": [mutation], "message": "Unable to react to a locked conversation"]],
            ]
            return (try JSONSerialization.data(withJSONObject: refusal), fakeResponse(url, status: 200))
        }
        guard let groups = changeReactions(of: subjectId, { setReaction(content, added: added, by: FakeGitHub.viewer, in: &$0) }) else {
            return try refusal(unresolved: subjectId, mutation: mutation, url)
        }
        let probe = try require(try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/add-reaction.json"))) as? [String: Any])
        var payload = try require((probe["data"] as? [String: Any])?["addReaction"] as? [String: Any])
        payload["subject"] = ["reactionGroups": groups]
        return (try JSONSerialization.data(withJSONObject: ["data": [mutation: payload]]), fakeResponse(url, status: 200))
    }

    /// Changes the reaction groups of whatever has `subjectId`, wherever it is, returning them
    /// as changed; nil if nothing has that id.
    @discardableResult
    private func changeReactions(of subjectId: String, _ change: (inout [[String: Any]]) -> Void) -> [[String: Any]]? {
        if var node = nodes[subjectId] {
            var groups = node["reactionGroups"] as? [[String: Any]] ?? noReactions
            change(&groups)
            node["reactionGroups"] = groups
            nodes[subjectId] = node
            return groups
        }
        for (id, timeline) in timelines {
            guard let index = timeline.firstIndex(where: { $0["id"] as? String == subjectId }) else { continue }
            var groups = timeline[index]["reactionGroups"] as? [[String: Any]] ?? noReactions
            change(&groups)
            timelines[id]?[index]["reactionGroups"] = groups
            return groups
        }
        for id in nodes.keys {
            var threads = threads(of: id)
            for threadIndex in threads.indices {
                var comments = comments(of: threads[threadIndex])
                guard let index = comments.firstIndex(where: { $0["id"] as? String == subjectId }) else { continue }
                var groups = comments[index]["reactionGroups"] as? [[String: Any]] ?? noReactions
                change(&groups)
                comments[index]["reactionGroups"] = groups
                threads[threadIndex]["comments"] = ["nodes": comments]
                setThreads(threads, of: id)
                return groups
            }
        }
        return nil
    }

    /// One more or one fewer of `content`, as `login` reacts or stops.
    private func setReaction(_ content: String, added: Bool, by login: String, in groups: inout [[String: Any]]) {
        guard let index = groups.firstIndex(where: { $0["content"] as? String == content }) else { return }
        let isViewer = login == FakeGitHub.viewer
        if isViewer, groups[index]["viewerHasReacted"] as? Bool == added { return }
        let count = ((groups[index]["reactors"] as? [String: Any])?["totalCount"] as? Int) ?? 0
        groups[index]["reactors"] = ["totalCount": max(0, count + (added ? 1 : -1))]
        if isViewer { groups[index]["viewerHasReacted"] = added }
    }

    /// Sets the description and GitHub's rendering of it, a paragraph per block of lines.
    private func setBody(_ body: String, on node: inout [String: Any]) {
        node["body"] = body
        node["bodyHTML"] = rendered(body)
    }

    /// GitHub's rendering of `body`, a paragraph per block of lines.
    private func rendered(_ body: String) -> String {
        escaped(body).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").map { "<p dir=\"auto\">\($0)</p>" }.joined(separator: "\n")
    }

    private func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    /// GitHub's shape for a mutation refused over an id it can't resolve, as in
    /// `probe/viewed-mark-error.json`.
    private func refusal(unresolved id: String, mutation: String, _ url: URL) throws -> (Data, HTTPURLResponse) {
        let body: [String: Any] = [
            "data": [mutation: NSNull()],
            "errors": [[
                "type": "NOT_FOUND",
                "path": [mutation],
                "locations": [["line": 2, "column": 3]],
                "message": "Could not resolve to a node with the global id of '\(id)'",
            ]],
        ]
        return (try JSONSerialization.data(withJSONObject: body), fakeResponse(url, status: 200))
    }
}

/// The GitHub a PR's tab talks to: viewed files from `FakeViewedFiles`, conversations and
/// reviewers from `FakeConversations`, rendered markdown from `FakeMarkdown`, signed in as
/// `FakeGitHub.viewer`.
struct FakePullRequestDetails: HTTPTransport {
    var viewed = FakeViewedFiles()
    var conversations = FakeConversations()
    var markdown = FakeMarkdown()

    func client() -> GitHubClient {
        GitHubClient(token: { FakeGitHub.validToken }, transport: self)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        if request.url?.path() == "/markdown" { return try await markdown.send(request) }
        if request.url?.path().hasPrefix("/repos/") == true { return try await conversations.sendREST(request) }
        let data = try require(request.httpBody)
        let body = try require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let query = try require(body["query"] as? String)
        if query.contains("viewer { login }") {
            let url = try require(request.url)
            return (try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["login": FakeGitHub.viewer]]]), fakeResponse(url, status: 200))
        }
        let isConversation = [
            "timelineItems", "reviewThreads", "resolveReviewThread(", "requestReviews(", "assignableUsers(", "teams(", "updatePullRequest(", "PullRequest { body }", "suggestedReviewers",
            "addPullRequestReview", "submitPullRequestReview(", "deletePullRequestReview(", "deletePullRequestReviewComment(",
            "addReaction(", "removeReaction(", "addComment(",
            "PullRequestReviewComment { body }", "updatePullRequestReviewComment(", "updateIssueComment(", "updatePullRequestReview(", "deleteIssueComment(",
        ].contains { query.contains($0) }
        return isConversation ? try await conversations.send(request) : try await viewed.send(request)
    }
}

func fakeResponse(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
}

/// GitHub's eight reaction groups for something no one has reacted to, in its order.
private var noReactions: [[String: Any]] {
    ["THUMBS_UP", "THUMBS_DOWN", "LAUGH", "HOORAY", "CONFUSED", "HEART", "ROCKET", "EYES"].map {
        ["content": $0, "viewerHasReacted": false, "reactors": ["totalCount": 0]]
    }
}

/// The line, and its side, at 1-based `position` below a patch's first hunk header, as GitHub
/// counts a review comment's position.
private func row(atPosition position: Int, inPatch patch: String) -> (line: Int, side: String)? {
    var (counted, old, new) = (-1, 0, 0)
    for row in patch.split(separator: "\n", omittingEmptySubsequences: false) {
        counted += 1
        if let header = row.firstMatch(of: /^@@ -(\d+)(?:,\d+)? \+(\d+)/) {
            (old, new) = (Int(header.1) ?? 0, Int(header.2) ?? 0)
            continue
        }
        let isRemoved = row.first == "-"
        if counted == position { return isRemoved ? (old, "LEFT") : (new, "RIGHT") }
        if row.first != "+" { old += 1 }
        if !isRemoved { new += 1 }
    }
    return nil
}
