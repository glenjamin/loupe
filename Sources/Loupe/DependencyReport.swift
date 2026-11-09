import Foundation
import LoupeCore
import LoupeGit
import LoupeModel

/// `Loupe --dependencies <checkout> <base>...<head>`: the files a PR changing `base...head`
/// would review, in each order the file list offers, then each link between them and why, as a
/// check of how a reported PR is ordered. It only reads the checkout, as diffing does, and
/// opens no windows.
enum DependencyReport {
    static func run(checkout path: String, range spec: String) async -> Int32 {
        let parts = spec.components(separatedBy: "...")
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            FileHandle.standardError.write(Data("usage: Loupe --dependencies <checkout> <base>...<head>\n".utf8))
            return 2
        }
        let checkout = URL(filePath: path, directoryHint: .isDirectory)
        let differ = PullRequestDiffer()
        do {
            let range = try await differ.branchRange(base: parts[0], head: parts[1], in: checkout)
            let diff = try await differ.diff(range, in: checkout)
            let files = DiffParser.parse(diff.text)
            let clock = ContinuousClock()
            let start = clock.now
            let links = try await differ.links(among: files, over: range, in: checkout)
            let took = clock.now - start
            let graph = FileGraph(paths: files.map(\.path), links: links)
            var lines = ["\(files.count) files to review, \(diff.hidden.count) hidden; links found in \(took.formatted(.units(allowed: [.milliseconds])))"]
            for order in [FileOrder.topDown, .bottomUp] {
                lines.append("")
                lines.append(order == .topDown ? "Top down:" : "Bottom up:")
                for group in graph.groups(order) {
                    lines.append(group.isStandalone ? "  Standalone (\(group.files.count))" : "  Group (\(group.files.count))")
                    lines += group.files.map { "    \($0)" }
                }
            }
            lines.append("")
            lines.append("Links:")
            lines += graph.links.sorted { ($0.from, $0.to, $0.reason) < ($1.from, $1.to, $1.reason) }.map { "  \($0.from) -> \($0.to) (\($0.reason))" }
            print(lines.joined(separator: "\n"))
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
            return 1
        }
    }
}
