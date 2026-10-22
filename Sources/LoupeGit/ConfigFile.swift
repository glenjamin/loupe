import Foundation

/// Loupe's settings that are meant to be edited by hand as well as from the app, as JSON in the
/// user's config directory. Only the folders to look for checkouts in are kept here so far.
public struct ConfigFile: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `config.json` under `loupe` in `$XDG_CONFIG_HOME`, or in `~/.config` without it.
    public static var defaultURL: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.homeDirectory.appending(path: ".config", directoryHint: .isDirectory)
        return base.appending(components: "loupe", "config.json")
    }

    /// The folders to look for checkouts in, in order, or nil if none have been chosen, as before
    /// the first launch. A leading `~` stands for the home directory.
    public func checkoutFolders() throws -> [URL]? {
        guard let settings = try read() else { return nil }
        return settings.checkoutFolders?.map(expandingTilde)
    }

    /// Keeps `folders` as the ones to look for checkouts in, writing those under the home
    /// directory with a leading `~`.
    public func setCheckoutFolders(_ folders: [URL]) throws {
        var settings = try read() ?? Settings()
        settings.checkoutFolders = folders.map(abbreviatingHome)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(settings).write(to: url, options: .atomic)
    }

    private func read() throws -> Settings? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        }
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    private struct Settings: Codable {
        var checkoutFolders: [String]?
    }
}

private func expandingTilde(_ path: String) -> URL {
    guard path == "~" || path.hasPrefix("~/") else { return URL(filePath: path, directoryHint: .isDirectory) }
    return URL.homeDirectory.appending(path: String(path.dropFirst(2)), directoryHint: .isDirectory)
}

private func abbreviatingHome(_ folder: URL) -> String {
    let path = folder.standardizedFileURL.path(percentEncoded: false)
    let home = URL.homeDirectory.standardizedFileURL.path(percentEncoded: false)
    let trimmed = path.hasSuffix("/") && path.count > 1 ? String(path.dropLast()) : path
    let homeTrimmed = home.hasSuffix("/") ? String(home.dropLast()) : home
    if trimmed == homeTrimmed { return "~" }
    return trimmed.hasPrefix(homeTrimmed + "/") ? "~" + trimmed.dropFirst(homeTrimmed.count) : trimmed
}
