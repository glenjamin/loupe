import Foundation

/// GitHub's REST markdown renderer. Like `POST /markdown` it takes JSON with the text, a mode
/// and the repo references resolve against, refuses a bad token, and answers with bare HTML: a
/// `#` line as a heading and anything else as paragraphs, escaped. Tests can make it fail.
actor FakeMarkdown {
    struct Request: Equatable, Decodable {
        let text: String
        let mode: String
        let context: String
    }

    /// Every request received, in order.
    private(set) var requests: [Request] = []
    private var failing = false

    func fail() { failing = true }
    func recover() { failing = false }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try require(request.url)
        try expect(url.absoluteString == "https://api.github.com/markdown")
        try expect(request.httpMethod == "POST")
        guard request.value(forHTTPHeaderField: "Authorization") == "bearer \(FakeGitHub.validToken)" else {
            return (Data(#"{"message":"Bad credentials"}"#.utf8), fakeResponse(url, status: 401))
        }
        let body = try JSONDecoder().decode(Request.self, from: try require(request.httpBody))
        requests.append(body)
        if failing { return (Data(#"{"message":"Server Error"}"#.utf8), fakeResponse(url, status: 500)) }
        return (Data(render(body.text).utf8), fakeResponse(url, status: 200))
    }
}

private func render(_ text: String) -> String {
    text.split(separator: "\n\n").map { block in
        let escaped = block.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return escaped.hasPrefix("# ") ? "<h1>\(escaped.dropFirst(2))</h1>" : "<p>\(escaped)</p>"
    }.joined(separator: "\n")
}
