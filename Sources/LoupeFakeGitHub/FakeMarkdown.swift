import Foundation

/// GitHub's REST markdown renderer. Like `POST /markdown` it takes JSON with the text, a mode
/// and the repo references resolve against, refuses a bad token, and answers with bare HTML: a
/// `#` line as a heading, a mermaid fence as GitHub's markup for github.com to draw, and anything
/// else as paragraphs, escaped. Tests can make it fail.
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
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        if let diagram = trimmed.wholeMatch(of: /```mermaid\n(?<source>(?s:.*)\n)```/) {
            return mermaidSection(String(diagram.source))
        }
        let escaped = escaped(trimmed)
        return escaped.hasPrefix("# ") ? "<h1>\(escaped.dropFirst(2))</h1>" : "<p>\(escaped)</p>"
    }.joined(separator: "\n")
}

/// A mermaid diagram as GitHub sends it: its source, marked for github.com to draw in a frame
/// from its own host, with a spinner while it does.
private func mermaidSection(_ source: String) -> String {
    let source = escaped(source)
    let attribute = source.replacingOccurrences(of: "\"", with: "&quot;")
    return """
        <section class="js-render-needs-enrichment render-needs-enrichment position-relative" data-identity="00000000-0000-0000-0000-000000000000" data-host="https://viewscreen.githubusercontent.com" data-src="https://viewscreen.githubusercontent.com/markdown/mermaid?docs_host=https%3A%2F%2Fdocs.github.com" data-type="mermaid" aria-label="mermaid rendered output container">
          <div class="js-render-enrichment-target" data-plain="\(attribute)" dir="auto">
            <div class="render-plaintext-hidden" dir="auto">
              <pre lang="mermaid" aria-label="Raw mermaid code" class="notranslate">\(source)</pre>
            </div>
          </div>
          <span class="js-render-enrichment-loader d-flex flex-justify-center flex-items-center width-full" style="min-height:100px" role="presentation">
            <span data-view-component="true"><svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true" class="octospinner mx-auto anim-rotate"></svg><span class="sr-only">Loading</span></span>
          </span>
        </section>
        """
}

private func escaped(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
}
