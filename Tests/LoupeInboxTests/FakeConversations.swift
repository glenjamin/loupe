import Foundation
import LoupeGitHub
import Testing

/// GitHub's conversations of PRs, each starting as the one captured in `probe/conversation.json`.
/// Like GitHub's GraphQL API it pages a PR's timeline with cursors at no more than the page size
/// asked for, answers a page after the first with the timeline alone, and has no node for a PR it
/// doesn't know. Its repos' people and teams are those in `probe/reviewer-candidates.json`, which
/// it pages with cursors as GitHub does; asking them to review adds them to a PR's review
/// requests, and asking anyone it doesn't know is refused, as GitHub refuses an id it can't
/// resolve. A PR's description can be asked for alone and replaced with `updatePullRequest`,
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
/// or make every request fail.
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
    }

    enum ReviewMutation: Equatable {
        case addReview(pullRequestId: String, commitId: String?, body: String?, event: String?, threads: [ThreadInput])
        case addThread(reviewId: String, ThreadInput)
        case submit(reviewId: String, event: String, body: String?)
        case delete(reviewId: String)
        case deleteComment(id: String)
    }

    struct ThreadInput: Equatable {
        let path: String
        let line: Int
        let side: String
        let body: String
    }
    private var timelines: [String: [[String: Any]]] = [:]
    private var failing = false
    private var teamsHidden = false
    private var editsRefused = false
    /// How many timeline pages have been served, first pages included.
    private(set) var pagesServed = 0
    /// The input of every `requestReviews` received, in order.
    private(set) var reviewRequestsReceived: [ReviewRequestInput] = []
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

    struct CommentInput: Equatable {
        let repository: String
        let number: Int
        let body: String
        let commitId: String
        let path: String
        let line: Int
        let side: String
    }
    /// Every reply to a thread received, in order.
    private(set) var repliesReceived: [ReplyInput] = []
    /// Every resolve or unresolve received, in order.
    private(set) var resolutionsReceived: [ResolutionInput] = []
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

    struct UpdateInput: Equatable {
        let pullRequestId: String
        let body: String?
    }

    /// Gives the PR with `id` the probe's conversation, and with its `number` it can be
    /// commented on over REST, which names PRs by number.
    func add(_ id: String, number: Int? = nil) throws {
        if let number { numbers[number] = id }
        let probe = try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/conversation.json")))
        var node = try #require(((probe as? [String: Any])?["data"] as? [String: Any])?["node"] as? [String: Any])
        let timeline = try #require(node["timelineItems"] as? [String: Any])
        timelines[id] = try #require(timeline["nodes"] as? [[String: Any]])
        node["timelineItems"] = nil
        nodes[id] = node
        try loadPeople()
    }

    /// Adds a comment to the end of the PR's timeline.
    func comment(_ bodyHTML: String, on id: String, by login: String = "octocat") {
        let index = timelines[id, default: []].count
        timelines[id, default: []].append([
            "__typename": "IssueComment",
            "id": "IC_fake_\(index)",
            "bodyHTML": bodyHTML,
            "createdAt": Date.now.formatted(.iso8601),
            "isMinimized": false,
            "author": ["login": login, "avatarUrl": "https://avatars.githubusercontent.com/u/583231?v=4"],
        ])
    }

    /// Starts a review thread on the PR, as a reviewer does on github.com, in the shape of
    /// `probe/review-threads.json`, and returns its id. An outdated thread has only its
    /// original line, as GitHub keeps it; `line: nil` without that is on the whole file.
    /// A thread in the viewer's pending review can't be resolved until it's submitted.
    @discardableResult
    func startThread(on id: String, path: String, line: Int?, side: String = "RIGHT", startLine: Int? = nil, outdated: Bool = false, resolved: Bool = false, pending: Bool = false, body: String, by login: String = "octocat") throws -> String {
        var node = try #require(nodes[id])
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
            "startDiffSide": startLine == nil ? NSNull() : side,
            "originalLine": line as Any? ?? NSNull(),
            "originalStartLine": startLine as Any? ?? NSNull(),
            "subjectType": line == nil ? "FILE" : "LINE",
            "viewerCanReply": true,
            "viewerCanResolve": !resolved && !pending,
            "viewerCanUnresolve": resolved,
            "resolvedBy": resolved ? ["login": login] : NSNull(),
            "firstComment": ["nodes": [["diffHunk": "@@ -1,2 +1,2 @@\n-old \(path)\n+new \(path)"]]],
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
    /// answers any request of them, as on GitHub.
    func review(_ state: String, by login: String, on id: String) throws {
        let user = try self.user(login)
        var node = try #require(nodes[id])
        var reviews = ((node["latestReviews"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        reviews.removeAll { ($0["author"] as? [String: Any])?["login"] as? String == login }
        reviews.append(["state": state, "submittedAt": Date.now.formatted(.iso8601), "author": user])
        node["latestReviews"] = ["nodes": reviews]
        let requests = ((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        node["reviewRequests"] = ["nodes": requests.filter { ($0["requestedReviewer"] as? [String: Any])?["login"] as? String != login }]
        nodes[id] = node
    }

    /// Asks the user with `login` to review, as from github.com.
    func request(_ login: String, on id: String) throws {
        try addRequest(user(login), on: id)
    }

    func hideTeams() { teamsHidden = true }

    /// Replaces the PR's description, as its author does on github.com.
    func editBody(_ body: String, on id: String) throws {
        var node = try #require(nodes[id])
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

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        #expect(url.absoluteString == "https://api.github.com/graphql")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "bearer \(FakeGitHub.validToken)")
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let query = try #require(body["query"] as? String)
        let variables = try #require(body["variables"] as? [String: Any])
        if query.contains("assignableUsers(") || query.contains("teams(") { candidatePagesAskedFor += 1 }
        if failing { return (Data(), fakeResponse(url, status: 502)) }
        if query.contains("requestReviews(") { return try requestReviews(variables, url) }
        if query.contains("assignableUsers(") { return try usersPage(variables, url) }
        if query.contains("teams(") { return try teamsPage(variables, url) }
        if query.contains("updatePullRequest(") { return try updatePullRequest(variables, url) }
        if query.contains("resolveReviewThread(") { return try setResolved(query.contains("unresolveReviewThread("), variables, url) }
        if query.contains("addPullRequestReviewThread(") { return try addReviewThread(variables, url) }
        if query.contains("addPullRequestReview(") { return try await addReview(variables, url) }
        if query.contains("submitPullRequestReview(") { return try await submitReview(variables, url) }
        if query.contains("deletePullRequestReviewComment(") { return try deleteReviewComment(variables, url) }
        if query.contains("deletePullRequestReview(") { return try deleteReview(variables, url) }
        if query.contains("suggestedReviewers") { return try suggestedReviewers(variables, url) }
        let id = try #require(variables["id"] as? String)
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
            return (try JSONSerialization.data(withJSONObject: ["data": ["node": answer]]), fakeResponse(url, status: 200))
        }
        if !query.contains("timelineItems") {
            #expect(query.contains("PullRequest { body }"), "the only query of a PR without its timeline is for its description")
            return (try JSONSerialization.data(withJSONObject: ["data": ["node": ["body": node["body"] ?? ""]]]), fakeResponse(url, status: 200))
        }
        let first = try #require(query.firstMatch(of: /timelineItems\(first: (\d+)/).flatMap { Int($0.1) })
        #expect(first <= 100, "GitHub's maximum page size")
        let start = try (variables["after"] as? String).map { try #require(Int($0)) } ?? 0
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
        return (try JSONSerialization.data(withJSONObject: ["data": ["node": node]]), fakeResponse(url, status: 200))
    }

    private func requestReviews(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = try #require(variables["input"] as? [String: Any])
        let id = try #require(input["pullRequestId"] as? String)
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

    /// A REST request: a reply to a review thread, at
    /// `/repos/{owner}/{repo}/pulls/{number}/comments/{comment_id}/replies`. Like GitHub, it
    /// takes only the REST id of a thread's first comment, as replies to replies aren't
    /// supported, and answers 201 with the new comment in `probe/review-comment-rest.json`'s shape.
    func sendREST(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "bearer \(FakeGitHub.validToken)")
        let data = try #require(request.httpBody)
        let content = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        if failing { return (Data(), fakeResponse(url, status: 502)) }
        if let match = url.path().wholeMatch(of: /\/repos\/([^\/]+\/[^\/]+)\/pulls\/(\d+)\/comments/) {
            return try newComment(content, repository: String(match.1), number: try #require(Int(match.2)), url)
        }
        let match = try #require(url.path().wholeMatch(of: /\/repos\/([^\/]+\/[^\/]+)\/pulls\/(\d+)\/comments\/(\d+)\/replies/), "Unexpected REST request: \(url.path())")
        let commentId = try #require(Int(match.3))
        let body = try #require(content["body"] as? String)
        repliesReceived.append(ReplyInput(repository: String(match.1), number: try #require(Int(match.2)), commentId: commentId, body: body))
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
        var rest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/review-comment-rest.json"))) as? [String: Any])
        rest["id"] = comment["databaseId"]
        rest["node_id"] = comment["id"]
        rest["body"] = body
        rest["in_reply_to_id"] = commentId
        return (try JSONSerialization.data(withJSONObject: rest), fakeResponse(url, status: 201))
    }

    /// A new comment on a line, which starts a thread by the viewer at once, answered as
    /// GitHub does with the comment.
    private func newComment(_ content: [String: Any], repository: String, number: Int, _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = CommentInput(
            repository: repository, number: number, body: try #require(content["body"] as? String), commitId: try #require(content["commit_id"] as? String),
            path: try #require(content["path"] as? String), line: try #require(content["line"] as? Int), side: try #require(content["side"] as? String)
        )
        commentsReceived.append(input)
        if threadChangesRefused {
            return (Data(#"{"message":"Resource not accessible by personal access token","status":"403"}"#.utf8), fakeResponse(url, status: 403))
        }
        guard let id = numbers[number] else {
            return (Data(#"{"message":"Not Found","status":"404"}"#.utf8), fakeResponse(url, status: 404))
        }
        try startThread(on: id, path: input.path, line: input.line, side: input.side, body: input.body, by: FakeGitHub.viewer)
        let comment = try #require(threads(of: id).last.flatMap { (($0["comments"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first })
        var rest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/review-comment-rest.json"))) as? [String: Any])
        rest["id"] = comment["databaseId"]
        rest["node_id"] = comment["id"]
        rest["body"] = input.body
        rest["path"] = input.path
        rest["line"] = input.line
        rest["side"] = input.side
        rest["commit_id"] = input.commitId
        rest["in_reply_to_id"] = nil
        return (try JSONSerialization.data(withJSONObject: rest), fakeResponse(url, status: 201))
    }

    /// Refuses replies and resolving, as for a PR the token can't write to.
    func refuseThreadChanges() { threadChangesRefused = true }

    private func setResolved(_ unresolve: Bool, _ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let mutation = unresolve ? "unresolveReviewThread" : "resolveReviewThread"
        let threadId = try #require(variables["threadId"] as? String)
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
        let index = try #require(list.firstIndex { $0["id"] as? String == threadId })
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
        let index = try #require(list.firstIndex { $0["id"] as? String == threadId })
        list[index]["comments"] = ["nodes": comments(of: list[index]) + [threadComment(body, by: FakeGitHub.viewer, pending: true)]]
        setThreads(list, of: id)
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

    private func pendingComments(of id: String) -> Int {
        threads(of: id).reduce(0) { count, thread in
            count + (((thread["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []).count { $0["state"] as? String == "PENDING" }
        }
    }

    private func addReview(_ variables: [String: Any], _ url: URL) async throws -> (Data, HTTPURLResponse) {
        let input = try #require(variables["input"] as? [String: Any])
        let id = try #require(input["pullRequestId"] as? String)
        let threads = try (input["threads"] as? [[String: Any]] ?? []).map(threadInput)
        let event = input["event"] as? String
        let body = input["body"] as? String
        reviewMutationsReceived.append(.addReview(pullRequestId: id, commitId: input["commitOID"] as? String, body: body, event: event, threads: threads))
        if let refusal = try refusalOfReviewChanges("addPullRequestReview", url) { return refusal }
        guard nodes[id] != nil else { return try refusal(unresolved: id, mutation: "addPullRequestReview", url) }
        if pendingReviews[id] != nil {
            return try unprocessable("addPullRequestReview", "User can only have one pending review per pull request", url)
        }
        if let event, event != "APPROVE", (body ?? "").isEmpty, threads.isEmpty {
            return try unprocessable("addPullRequestReview", "Review body is required for \(event)", url)
        }
        let reviewId = newReviewId()
        for thread in threads {
            try startThread(on: id, path: thread.path, line: thread.line, side: thread.side, pending: event == nil, body: thread.body, by: FakeGitHub.viewer)
        }
        if let event {
            try await recordReview(event, body: body ?? "", on: id)
        } else {
            pendingReviews[id] = PendingReviewState(id: reviewId, body: body ?? "")
        }
        let payload: [String: Any] = ["addPullRequestReview": ["pullRequestReview": ["id": reviewId, "state": event == nil ? "PENDING" : "SUBMITTED"]]]
        return (try JSONSerialization.data(withJSONObject: ["data": payload]), fakeResponse(url, status: 200))
    }

    private func addReviewThread(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = try #require(variables["input"] as? [String: Any])
        let reviewId = try #require(input["pullRequestReviewId"] as? String)
        let thread = try threadInput(input)
        reviewMutationsReceived.append(.addThread(reviewId: reviewId, thread))
        if let refusal = try refusalOfReviewChanges("addPullRequestReviewThread", url) { return refusal }
        guard let id = pullRequest(withPendingReview: reviewId) else { return try refusal(unresolved: reviewId, mutation: "addPullRequestReviewThread", url) }
        let threadId = try startThread(on: id, path: thread.path, line: thread.line, side: thread.side, pending: true, body: thread.body, by: FakeGitHub.viewer)
        return (try JSONSerialization.data(withJSONObject: ["data": ["addPullRequestReviewThread": ["thread": ["id": threadId]]]]), fakeResponse(url, status: 200))
    }

    private func submitReview(_ variables: [String: Any], _ url: URL) async throws -> (Data, HTTPURLResponse) {
        let input = try #require(variables["input"] as? [String: Any])
        let reviewId = try #require(input["pullRequestReviewId"] as? String)
        let event = try #require(input["event"] as? String)
        let body = input["body"] as? String
        reviewMutationsReceived.append(.submit(reviewId: reviewId, event: event, body: body))
        if let refusal = try refusalOfReviewChanges("submitPullRequestReview", url) { return refusal }
        guard let id = pullRequest(withPendingReview: reviewId) else { return try refusal(unresolved: reviewId, mutation: "submitPullRequestReview", url) }
        if event != "APPROVE", (body ?? "").isEmpty, pendingComments(of: id) == 0 {
            return try unprocessable("submitPullRequestReview", "Review body is required for \(event)", url)
        }
        pendingReviews[id] = nil
        setThreads(threads(of: id).map { thread in
            var thread = thread
            let comments = ((thread["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
            // A thread the review started can be resolved once it's submitted.
            if comments.first?["state"] as? String == "PENDING" { thread["viewerCanResolve"] = true }
            thread["comments"] = ["nodes": comments.map { $0.merging(["state": "SUBMITTED"]) { $1 } }]
            return thread
        }, of: id)
        try await recordReview(event, body: body ?? "", on: id)
        return (try JSONSerialization.data(withJSONObject: ["data": ["submitPullRequestReview": ["pullRequestReview": ["id": reviewId, "state": "SUBMITTED"]]]]), fakeResponse(url, status: 200))
    }

    private func deleteReview(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = try #require(variables["input"] as? [String: Any])
        let reviewId = try #require(input["pullRequestReviewId"] as? String)
        reviewMutationsReceived.append(.delete(reviewId: reviewId))
        if let refusal = try refusalOfReviewChanges("deletePullRequestReview", url) { return refusal }
        guard let id = pullRequest(withPendingReview: reviewId) else { return try refusal(unresolved: reviewId, mutation: "deletePullRequestReview", url) }
        pendingReviews[id] = nil
        // Its comments go, and with them any thread it started.
        setThreads(threads(of: id).compactMap { thread in
            var thread = thread
            let comments = (((thread["comments"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []).filter { $0["state"] as? String != "PENDING" }
            guard !comments.isEmpty else { return nil }
            thread["comments"] = ["nodes": comments]
            return thread
        }, of: id)
        return (try JSONSerialization.data(withJSONObject: ["data": ["deletePullRequestReview": ["pullRequestReview": ["id": reviewId]]]]), fakeResponse(url, status: 200))
    }

    /// Deletes a comment wherever it is, and its thread once it has none; a pending review left
    /// with no comments stays, as GitHub keeps it. Answers in `probe/delete-review-comment.json`'s
    /// shape.
    private func deleteReviewComment(_ variables: [String: Any], _ url: URL) throws -> (Data, HTTPURLResponse) {
        let input = try #require(variables["input"] as? [String: Any])
        let commentId = try #require(input["id"] as? String)
        reviewMutationsReceived.append(.deleteComment(id: commentId))
        if let refusal = try refusalOfReviewChanges("deletePullRequestReviewComment", url) { return refusal }
        guard let id = nodes.keys.first(where: { threads(of: $0).contains { comments(of: $0).contains { $0["id"] as? String == commentId } } }) else {
            return try refusal(unresolved: commentId, mutation: "deletePullRequestReviewComment", url)
        }
        setThreads(threads(of: id).compactMap { thread in
            var thread = thread
            let comments = comments(of: thread).filter { $0["id"] as? String != commentId }
            guard !comments.isEmpty else { return nil }
            thread["comments"] = ["nodes": comments]
            return thread
        }, of: id)
        let probe = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/delete-review-comment.json"))) as? [String: Any])
        var payload = try #require((probe["data"] as? [String: Any])?["deletePullRequestReviewComment"] as? [String: Any])
        var review = try #require(payload["pullRequestReview"] as? [String: Any])
        if let pending = pendingReviews[id] { review["id"] = pending.id }
        payload["pullRequestReview"] = review
        return (try JSONSerialization.data(withJSONObject: ["data": ["deletePullRequestReviewComment": payload]]), fakeResponse(url, status: 200))
    }

    /// The viewer's submitted review: their latest, in the timeline, and the PR's review
    /// decision where it decides one.
    private func recordReview(_ event: String, body: String, on id: String) async throws {
        let state = ["APPROVE": "APPROVED", "REQUEST_CHANGES": "CHANGES_REQUESTED"][event] ?? "COMMENTED"
        try review(state, by: FakeGitHub.viewer, on: id)
        let index = timelines[id, default: []].count
        timelines[id, default: []].append([
            "__typename": "PullRequestReview",
            "id": "PRR_fake_timeline_\(index)",
            "state": state,
            "bodyHTML": body.isEmpty ? "" : "<p dir=\"auto\">\(escaped(body))</p>",
            "createdAt": Date.now.formatted(.iso8601),
            "submittedAt": Date.now.formatted(.iso8601),
            "author": ["login": FakeGitHub.viewer, "avatarUrl": "https://avatars.githubusercontent.com/u/151272?v=4"],
            "comments": ["nodes": []],
        ])
        guard let github, state != "COMMENTED" else { return }
        try await github.edit(id) { $0.reviewDecision = state }
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
            path: try #require(input["path"] as? String), line: try #require(input["line"] as? Int),
            side: try #require(input["side"] as? String), body: try #require(input["body"] as? String)
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
        let input = try #require(variables["input"] as? [String: Any])
        let id = try #require(input["pullRequestId"] as? String)
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
        let node = try #require(((probe as? [String: Any])?["data"] as? [String: Any])?["node"] as? [String: Any])
        suggestions[id] = try #require(node["suggestedReviewers"] as? [[String: Any]])
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
        let id = try #require(variables["id"] as? String)
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
        let first = try #require(variables["first"] as? Int)
        #expect(first <= 100, "GitHub's maximum page size")
        let start = try (variables["after"] as? String).map { try #require(Int($0)) } ?? 0
        let end = min(start + min(first, candidatePageSize), nodes.count)
        return [
            "pageInfo": ["hasNextPage": end < nodes.count, "endCursor": end > start ? String(end) as Any : NSNull()],
            "nodes": Array(nodes[start..<end]),
        ]
    }

    /// GitHub keeps one request per reviewer, so asking again leaves the one there.
    private func addRequest(_ reviewer: [String: Any], on id: String) throws {
        var node = try #require(nodes[id])
        var requests = ((node["reviewRequests"] as? [String: Any])?["nodes"] as? [[String: Any]]) ?? []
        let reviewerId = reviewer["id"] as? String
        if !requests.contains(where: { ($0["requestedReviewer"] as? [String: Any])?["id"] as? String == reviewerId }) {
            requests.append(["requestedReviewer": reviewer])
        }
        node["reviewRequests"] = ["nodes": requests]
        nodes[id] = node
    }

    /// The user with `login`, shaped as the conversation query's `Reviewer` fragment returns them.
    private func user(_ login: String) throws -> [String: Any] {
        try #require(users.first { $0["login"] as? String == login })
    }

    private func loadPeople() throws {
        guard users.isEmpty else { return }
        let probe = try JSONSerialization.jsonObject(with: Data(contentsOf: projectRoot.appending(path: "probe/reviewer-candidates.json")))
        let repository = try #require(((probe as? [String: Any])?["data"] as? [String: Any])?["repository"] as? [String: Any])
        let assignable = try #require((repository["assignableUsers"] as? [String: Any])?["nodes"] as? [[String: Any]])
        users = assignable.map { $0.merging(["__typename": "User"]) { $1 } }
        teams = try #require(((repository["owner"] as? [String: Any])?["teams"] as? [String: Any])?["nodes"] as? [[String: Any]])
    }

    /// A new thread comment in the review threads query's shape, with GitHub's rendering of
    /// `body` as one paragraph and the next REST id.
    private func threadComment(_ body: String, by login: String, pending: Bool = false) -> [String: Any] {
        commentCount += 1
        return [
            "id": "PRRC_fake_\(commentCount)",
            "databaseId": 900_000 + commentCount,
            "bodyHTML": "<p dir=\"auto\">\(escaped(body))</p>",
            "createdAt": Date.now.formatted(.iso8601),
            "isMinimized": false,
            "minimizedReason": NSNull(),
            "state": pending ? "PENDING" : "SUBMITTED",
            "author": ["login": login, "avatarUrl": "https://avatars.githubusercontent.com/u/583231?v=4"],
        ]
    }

    /// Sets the description and GitHub's rendering of it, a paragraph per block of lines.
    private func setBody(_ body: String, on node: inout [String: Any]) {
        node["body"] = body
        node["bodyHTML"] = escaped(body).replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").map { "<p dir=\"auto\">\($0)</p>" }.joined(separator: "\n")
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
        let data = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let query = try #require(body["query"] as? String)
        if query.contains("viewer { login }") {
            let url = try #require(request.url)
            return (try JSONSerialization.data(withJSONObject: ["data": ["viewer": ["login": FakeGitHub.viewer]]]), fakeResponse(url, status: 200))
        }
        let isConversation = [
            "timelineItems", "reviewThreads", "resolveReviewThread(", "requestReviews(", "assignableUsers(", "teams(", "updatePullRequest(", "PullRequest { body }", "suggestedReviewers",
            "addPullRequestReview", "submitPullRequestReview(", "deletePullRequestReview(", "deletePullRequestReviewComment(",
        ].contains { query.contains($0) }
        return isConversation ? try await conversations.send(request) : try await viewed.send(request)
    }
}

func fakeResponse(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
}
