import Foundation
import os

/// GitHub Linguist's data, as `Scripts/update-linguist.sh` vendors it under `Resources/linguist`,
/// so Loupe names languages and hides files the way GitHub does.
enum Linguist {
    static let languages = LanguageIndex(load("languages", as: [String: LanguageEntry].self) ?? [:])
    static let vendored = PathPatterns(load("vendor", as: [String].self) ?? [])
    static let documentation = PathPatterns(load("documentation", as: [String].self) ?? [])
}

/// Looks a path's language up as Linguist does from its name alone: an exact file name, then
/// the longest known extension, then the name less its last extension (`Dockerfile.prod`).
/// Linguist's interpreter, modeline and content heuristics aren't run, so an ambiguous
/// extension yields every language that claims it, in name order.
struct LanguageIndex: Sendable {
    private var byFilename: [String: [String]] = [:]
    private var byExtension: [String: [String]] = [:]

    init(_ entries: [String: LanguageEntry]) {
        for (name, entry) in entries.sorted(by: { $0.key < $1.key }) {
            for filename in entry.filenames ?? [] { byFilename[filename, default: []].append(name) }
            for ext in entry.extensions ?? [] { byExtension[ext.lowercased(), default: []].append(name) }
        }
    }

    func languages(forPath path: String) -> [String] {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        if let found = byFilename[name] { return found }
        if let found = extensions(of: name).lazy.compactMap({ byExtension[$0] }).first { return found }
        if let dot = name.lastIndex(of: "."), dot != name.startIndex, let found = byFilename[String(name[..<dot])] { return found }
        return []
    }
}

struct LanguageEntry: Decodable {
    var extensions: [String]?
    var filenames: [String]?
}

/// A list of Linguist's path regexes, compiled once. Linguist writes them for Ruby; any ICU
/// can't compile is skipped and logged. ICU tries an alternation's branches one by one, so most
/// patterns, which are anchored to the start of a path segment, are grouped by the character
/// they start with and tried only where a segment starts with it.
struct PathPatterns: Sendable {
    private let atStart: NSRegularExpression?
    private let atSegment: [Character: NSRegularExpression]
    private let atAnySegment: NSRegularExpression?
    private let anywhere: NSRegularExpression?

    init(_ patterns: [String]) {
        var atStart: [String] = []
        var atSegment: [Character: [String]] = [:]
        var atAnySegment: [String] = []
        var anywhere: [String] = []
        for pattern in patterns {
            guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                logger.warning("Skipping Linguist pattern ICU can't compile: \(pattern, privacy: .public)")
                continue
            }
            if let rest = dropPrefix(of: pattern, among: ["(^|/)", "(^|\\/)"]) {
                if let first = leadingCharacters(of: rest) {
                    for character in first { atSegment[character, default: []].append(rest) }
                } else {
                    atAnySegment.append(rest)
                }
            } else if pattern.hasPrefix("^") {
                atStart.append(String(pattern.dropFirst()))
            } else {
                // A leading match-anything only makes an unanchored search rescan from every position.
                anywhere.append(dropPrefix(of: pattern, among: ["(.*?)", "(.*)", ".*?", ".*", "([^\\s]*)"]) ?? pattern)
            }
        }
        self.atStart = alternation(atStart)
        self.atSegment = atSegment.compactMapValues(alternation)
        self.atAnySegment = alternation(atAnySegment)
        self.anywhere = alternation(anywhere)
    }

    func matches(_ path: String) -> Bool {
        let text = path as NSString
        let whole = NSRange(location: 0, length: text.length)
        if let atStart, atStart.firstMatch(in: path, options: .anchored, range: whole) != nil { return true }
        var start = path.startIndex
        while start < path.endIndex {
            let rest = NSRange(start..., in: path)
            let candidates = [atSegment[path[start]], atAnySegment].compactMap { $0 }
            if candidates.contains(where: { $0.firstMatch(in: path, options: .anchored, range: rest) != nil }) { return true }
            guard let slash = path[start...].firstIndex(of: "/") else { break }
            start = path.index(after: slash)
        }
        return anywhere?.firstMatch(in: path, range: whole) != nil
    }
}

private let logger = Logger(subsystem: "com.glenmailer.Loupe", category: "linguist")

/// Linguist's candidate extensions for a file name, longest first: `a.d.ts` gives `.d.ts`, `.ts`.
private func extensions(of name: String) -> [String] {
    let segments = name.lowercased().split(separator: ".", omittingEmptySubsequences: false).dropFirst()
    return segments.indices.map { "." + segments[$0...].joined(separator: ".") }
}

/// The characters any match of `pattern` must start with, where a literal or a simple class
/// makes that plain; nil otherwise.
private func leadingCharacters(of pattern: String) -> Set<Character>? {
    let characters = Array(pattern)
    guard let first = characters.first else { return nil }
    let set: Set<Character>
    let next: Int
    if first == "\\" {
        guard characters.count > 1, !characters[1].isLetter, !characters[1].isNumber else { return nil }
        (set, next) = ([characters[1]], 2)
    } else if first == "[" {
        guard let close = characters.firstIndex(of: "]") else { return nil }
        let members = characters[1..<close]
        guard !members.isEmpty, members.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        (set, next) = (Set(members), close + 1)
    } else if first.isLetter || first.isNumber || "_~-@".contains(first) {
        (set, next) = ([first], 1)
    } else {
        return nil
    }
    // An optional first character means the match could start with whatever follows it.
    if next < characters.count, "?*{".contains(characters[next]) { return nil }
    return set
}

private func dropPrefix(of pattern: String, among prefixes: [String]) -> String? {
    prefixes.first(where: pattern.hasPrefix).map { String(pattern.dropFirst($0.count)) }
}

private func alternation(_ patterns: [String]) -> NSRegularExpression? {
    patterns.isEmpty ? nil : try? NSRegularExpression(pattern: patterns.map { "(?:\($0))" }.joined(separator: "|"))
}

/// Reads one of the vendored JSON files from LoupeCore's resource bundle.
private func load<T: Decodable>(_ name: String, as type: T.Type) -> T? {
    guard let url = bundledResource("linguist/\(name).json", in: "Loupe_LoupeCore"), let data = try? Data(contentsOf: url) else {
        logger.error("Linguist's \(name, privacy: .public) data is missing from the bundle")
        return nil
    }
    do {
        return try JSONDecoder().decode(type, from: data)
    } catch {
        logger.error("Couldn't read Linguist's \(name, privacy: .public): \(error, privacy: .public)")
        return nil
    }
}

private final class BundleToken {}

/// A file in one of SwiftPM's resource bundles: beside the executable for `swift run` and tests,
/// in Contents/Resources inside the app. Found without `Bundle.module`, which only looks beside
/// the app and in the build directory, and stops the process if both miss.
func bundledResource(_ path: String, in bundle: String) -> URL? {
    let containers = [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent()]
    for container in containers.compactMap({ $0 }) {
        for resources in ["", "Contents/Resources/"] {
            let url = container.appending(path: "\(bundle).bundle/\(resources)\(path)")
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
    }
    return nil
}
