import Foundation
import LoupeModel

extension GitHubClient {
    /// Every emoji GitHub's markdown takes, by name. `GET /emojis` gives each an image; a Unicode
    /// emoji's is named by its code points, which give its character.
    public func emojis() async throws -> [Emoji] {
        let images = try JSONDecoder().decode([String: String].self, from: try await rest("GET", path: "/emojis"))
        return images.map { Emoji(name: $0.key, character: character(ofImage: $0.value)) }.sorted { $0.name < $1.name }
    }
}

/// The character an emoji's image stands for, from a name such as `unicode/1f1e6-1f1eb.png`, with
/// the emoji presentation selector where a code point alone would show as text (©, a keycap's #),
/// as GitHub's own rendering has it. None for GitHub's own emoji, which aren't under `unicode/`.
private func character(ofImage url: String) -> String? {
    guard let path = URL(string: url)?.path(), path.contains("/unicode/") else { return nil }
    let name = (path as NSString).lastPathComponent.split(separator: ".").first ?? ""
    let scalars = name.split(separator: "-").compactMap { UInt32($0, radix: 16).flatMap(Unicode.Scalar.init) }
    guard !scalars.isEmpty else { return nil }
    let selector = Unicode.Scalar(0xFE0F)!
    let keycap = Unicode.Scalar(0x20E3)!
    var shown: [Unicode.Scalar] = []
    for scalar in scalars {
        if scalar == keycap, shown.last != selector { shown.append(selector) }
        shown.append(scalar)
    }
    if shown.count == 1, !shown[0].properties.isEmojiPresentation { shown.append(selector) }
    return String(String.UnicodeScalarView(shown))
}
