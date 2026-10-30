import Foundation

/// GitHub's emoji list, `GET /emojis`, as `probe/emojis.json` has it, refusing a bad token.
struct FakeEmojis: Sendable {
    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try require(request.url)
        try expect(url.path() == "/emojis" && (request.httpMethod ?? "GET") == "GET", "only reads the emoji list")
        guard request.value(forHTTPHeaderField: "Authorization") == "bearer \(FakeGitHub.validToken)" else {
            return (Data(#"{"message":"Bad credentials"}"#.utf8), fakeResponse(url, status: 401))
        }
        return (try Data(contentsOf: projectRoot.appending(path: "probe/emojis.json")), fakeResponse(url, status: 200))
    }
}
