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
/// REST, which adds the viewer's comment, and resolved or unresolved. Tests can add comments,
/// reviews and review threads, ask for reviews or edit a description, as people do on GitHub,
/// hide the teams, as from a token without access to them, shrink the pages of people and
/// teams, refuse edits or changes to threads, as for a PR the token can't write to, or make
/// every request fail.
actor FakeConversations {
    /// Each PR's conversation, less its timeline, in GitHub's JSON shape.
    private var nodes: [String: [String: Any]] = [:]
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
    @discardableResult
    func startThread(on id: String, path: String, line: Int?, side: String = "RIGHT", startLine: Int? = nil, outdated: Bool = false, resolved: Bool = false, body: String, by login: String = "octocat") throws -> String {
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
            "viewerCanResolve": !resolved,
            "viewerCanUnresolve": resolved,
            "resolvedBy": resolved ? ["login": login] : NSNull(),
            "firstComment": ["nodes": [["diffHunk": "@@ -1,2 +1,2 @@\n-old \(path)\n+new \(path)"]]],
            "comments": ["nodes": [threadComment(body, by: login)]],
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

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
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
        let id = try #require(variables["id"] as? String)
        guard var node = nodes[id], let timeline = timelines[id] else {
            return (try JSONSerialization.data(withJSONObject: ["data": ["node": NSNull()]]), fakeResponse(url, status: 200))
        }
        if query.contains("reviewThreads"), !query.contains("timelineItems") {
            threadFetches += 1
            let threads = node["reviewThreads"] ?? ["nodes": []]
            return (try JSONSerialization.data(withJSONObject: ["data": ["node": ["reviewThreads": threads]]]), fakeResponse(url, status: 200))
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
            guard let user = users.first(where: { $0["id"] as? String == userId }) else { return try refusal(unresolved: userId, mutation: "requestReviews", url) }
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
    private func threadComment(_ body: String, by login: String) -> [String: Any] {
        commentCount += 1
        return [
            "id": "PRRC_fake_\(commentCount)",
            "databaseId": 900_000 + commentCount,
            "bodyHTML": "<p dir=\"auto\">\(escaped(body))</p>",
            "createdAt": Date.now.formatted(.iso8601),
            "isMinimized": false,
            "minimizedReason": NSNull(),
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
        let isConversation = ["timelineItems", "reviewThreads", "resolveReviewThread(", "requestReviews(", "assignableUsers(", "teams(", "updatePullRequest(", "PullRequest { body }"].contains { query.contains($0) }
        return isConversation ? try await conversations.send(request) : try await viewed.send(request)
    }
}

func fakeResponse(_ url: URL, status: Int) -> HTTPURLResponse {
    HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
}
