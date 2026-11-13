import Foundation

/// GitHub's uploaded attachments, `https://github.com/user-attachments/assets/<id>`: a signed-in
/// `HEAD` is sent on to a fresh signed URL each time, as GitHub's expire within minutes, and
/// anyone else is told there's no such thing. Only `ids` exist.
struct FakeAttachments: Sendable {
    var ids: Set<String> = [FakeAttachments.video]

    /// The id of the video every fake GitHub has.
    static let video = "0b5e7c1d-6a2f-4e8b-9d3c-1f2a3b4c5d6e"

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = try require(request.url)
        try expect(request.httpMethod == "HEAD", "only asks where it is, downloading nothing")
        let id = url.lastPathComponent
        guard request.value(forHTTPHeaderField: "Authorization") == "bearer \(FakeGitHub.validToken)", ids.contains(id) else {
            return (Data(), HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: [:])!)
        }
        let signed = "https://attachments.example/\(id).mp4?signature=\(UUID().uuidString)"
        return (Data(), HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": signed])!)
    }
}
