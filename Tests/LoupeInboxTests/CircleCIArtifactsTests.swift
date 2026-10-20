import Foundation
import LoupeInbox
import Testing

struct CircleCIArtifactsTests {
    @Test func theReportAndItsFilesAreFetchedWithTheTokenUnderLoupesOwnScheme() async throws {
        let circleCI = FakeCircleCI(token: "fake-token", files: [
            "/output/job/11111111-2222-4333-8444-555555555555/artifacts/0/diff-book/review/index.html": ("<script src=review.js></script>", "text/html"),
            "/output/job/11111111-2222-4333-8444-555555555555/artifacts/0/diff-book/review/review.js": ("swipe()", "text/javascript"),
        ])
        let artifacts = CircleCIArtifacts(token: CircleCIToken { "fake-token" }, transport: circleCI.transport)

        let page = try #require(CircleCIArtifacts.proxyURL(for: reportURL))
        #expect(page.absoluteString == "loupe-artifact://output.circle-artifacts.com/output/job/11111111-2222-4333-8444-555555555555/artifacts/0/diff-book/review/index.html")
        #expect(await artifacts.fetch(page) == .loaded(Data("<script src=review.js></script>".utf8), mimeType: "text/html", status: 200))
        // The page's relative script resolves under the same scheme, so it comes here too.
        let script = try #require(URL(string: "review.js", relativeTo: page)?.absoluteURL)
        #expect(await artifacts.fetch(script) == .loaded(Data("swipe()".utf8), mimeType: "text/javascript", status: 200))
        #expect(await circleCI.requested == [reportURL, try #require(URL(string: "review.js", relativeTo: reportURL)?.absoluteURL)])
    }

    @Test func onlyCircleCIsArtifactHostsAreFetched() async throws {
        #expect(CircleCIArtifacts.proxyURL(for: try #require(URL(string: "https://example.com/index.html"))) == nil)
        #expect(CircleCIArtifacts.proxyURL(for: try #require(URL(string: "http://output.circle-artifacts.com/x.html"))) == nil)
        let circleCI = FakeCircleCI(token: "fake-token", files: [:])
        let artifacts = CircleCIArtifacts(token: CircleCIToken { "fake-token" }, transport: circleCI.transport)

        let elsewhere = try #require(URL(string: "loupe-artifact://example.com/steal"))
        guard case .failed = await artifacts.fetch(elsewhere) else { Issue.record("fetched another host"); return }
        #expect(await circleCI.requested.isEmpty)
    }

    @Test func withNoTokenNothingIsAskedOfCircleCI() async throws {
        let circleCI = FakeCircleCI(token: "fake-token", files: [:])
        let artifacts = CircleCIArtifacts(token: CircleCIToken { nil }, transport: circleCI.transport)

        #expect(await artifacts.fetch(try #require(CircleCIArtifacts.proxyURL(for: reportURL))) == .needsToken)
        #expect(await circleCI.requested.isEmpty)
    }

    @Test func aRefusedTokenIsReadAfreshNextTime() async throws {
        let circleCI = FakeCircleCI(token: "new-token", files: [reportURL.path(): ("report", "text/html")])
        let reads = Reads(["old-token", "new-token"])
        let artifacts = CircleCIArtifacts(token: CircleCIToken { reads.next() }, transport: circleCI.transport)
        let page = try #require(CircleCIArtifacts.proxyURL(for: reportURL))

        #expect(await artifacts.fetch(page) == .refused(status: 401))
        #expect(await artifacts.fetch(page) == .loaded(Data("report".utf8), mimeType: "text/html", status: 200))
    }

    @Test func aMissingArtifactSaysSo() async throws {
        let circleCI = FakeCircleCI(token: "fake-token", files: [:])
        let artifacts = CircleCIArtifacts(token: CircleCIToken { "fake-token" }, transport: circleCI.transport)

        guard case .loaded(_, _, 404) = await artifacts.fetch(try #require(CircleCIArtifacts.proxyURL(for: reportURL))) else {
            Issue.record("expected CircleCI's 404")
            return
        }
    }

    @Test func theTokenIsReadWhereTheCLIDocumentsKeepingIt() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(CircleCIToken.fromCLISettings(environment: [:], home: home) == nil, "no settings yet")

        let config = home.appending(path: ".config/circleci/config.yml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "host: https://circleci.com\ntoken: fake-from-settings\nuser_id: someone\n".write(to: config, atomically: true, encoding: .utf8)
        #expect(CircleCIToken.fromCLISettings(environment: [:], home: home) == "fake-from-settings")
        #expect(CircleCIToken.fromCLISettings(environment: ["CIRCLE_TOKEN": "fake-from-env"], home: home) == "fake-from-env", "the environment wins, as for the CLI")

        let xdg = home.appending(path: "xdg", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: xdg.appending(path: "circleci"), withIntermediateDirectories: true)
        try "token: \"fake-from-xdg\"\n".write(to: xdg.appending(path: "circleci/config.yml"), atomically: true, encoding: .utf8)
        #expect(CircleCIToken.fromCLISettings(environment: ["XDG_CONFIG_HOME": xdg.path()], home: home) == "fake-from-xdg")
    }
}

private let reportURL = URL(string: "https://output.circle-artifacts.com/output/job/11111111-2222-4333-8444-555555555555/artifacts/0/diff-book/review/index.html")!

/// CircleCI's artifact host: serves its files by path to a request carrying the one token it
/// accepts in `Circle-Token`, 401 to any other, and 404 for a path it hasn't got.
private actor FakeCircleCI {
    let token: String
    let files: [String: (body: String, type: String)]
    private(set) var requested: [URL] = []

    init(token: String, files: [String: (body: String, type: String)]) {
        self.token = token
        self.files = files
    }

    nonisolated var transport: CircleCIArtifacts.Transport {
        { request in try await self.answer(request) }
    }

    private func answer(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try #require(request.url)
        requested.append(url)
        let respond = { (status: Int, body: String, type: String) throws -> (Data, HTTPURLResponse) in
            (Data(body.utf8), try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": type])))
        }
        guard request.value(forHTTPHeaderField: "Circle-Token") == token else { return try respond(401, #"{"message":"Unauthorized"}"#, "application/json") }
        guard let file = files[url.path()] else { return try respond(404, #"{"message":"not found"}"#, "application/json") }
        return try respond(200, file.body, file.type)
    }
}

/// Answers each read with the next of `values`, as a token replaced between reads would be.
private final class Reads: @unchecked Sendable {
    private var values: [String]
    private let lock = NSLock()

    init(_ values: [String]) { self.values = values }

    func next() -> String? {
        lock.withLock { values.isEmpty ? nil : values.removeFirst() }
    }
}
