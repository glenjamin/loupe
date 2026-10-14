/// Parses `git diff` output. Tolerant: unrecognised header lines are skipped rather than failing.
public enum DiffParser {
    public static func parse(_ text: String) -> [FileDiff] {
        var files: [FileDiff] = []
        var builder: FileBuilder?

        for line in splitLines(text) {
            if line.hasPrefix("diff --git ") {
                if let done = builder?.finish() { files.append(done) }
                builder = FileBuilder(gitHeader: line)
                continue
            }
            builder?.consume(line)
        }
        if let done = builder?.finish() { files.append(done) }
        return files
    }

    /// Parses bare hunks with no file header, such as a review comment's `diffHunk` from the GitHub API.
    public static func parseHunks(_ text: String) -> [Hunk] {
        var builder = FileBuilder(path: "")
        builder.inHeader = false
        for line in splitLines(text) { builder.consume(line) }
        return builder.finish().hunks
    }
}

private struct FileBuilder {
    var path: String
    var oldPath: String?
    var change: FileDiff.Change = .modified
    var similarity = 0
    var copiedFrom: String?
    var isBinary = false
    var hunks: [Hunk] = []
    var inHeader = true
    var oldNext = 0
    var newNext = 0

    init(path: String) {
        self.path = path
    }

    /// The `diff --git a/x b/y` path is ambiguous when names contain spaces, so it's only a fallback
    /// for diffs with no `---`/`+++` or rename lines (pure renames, mode changes, binaries).
    init(gitHeader: Substring) {
        let rest = gitHeader.dropFirst("diff --git ".count)
        let half = (rest.count - 1) / 2
        let candidate = rest.suffix(half)
        path = candidate.hasPrefix("b/") ? String(candidate.dropFirst(2)) : String(candidate)
    }

    mutating func consume(_ line: Substring) {
        if line.hasPrefix("@@") {
            startHunk(line)
            return
        }
        if inHeader {
            consumeHeader(line)
            return
        }
        guard !hunks.isEmpty else { return }
        let text = String(line.dropFirst())
        switch line.first {
        case " ":
            append(DiffLine(kind: .context(old: oldNext, new: newNext), text: text))
            oldNext += 1
            newNext += 1
        case "+":
            append(DiffLine(kind: .addition(new: newNext), text: text))
            newNext += 1
        case "-":
            append(DiffLine(kind: .deletion(old: oldNext), text: text))
            oldNext += 1
        case "\\":
            let last = hunks[hunks.count - 1].lines.count - 1
            if last >= 0 { hunks[hunks.count - 1].lines[last].missingNewline = true }
        default:
            // An empty line can appear where a context line's leading space was stripped (e.g. by an editor).
            if line.isEmpty {
                append(DiffLine(kind: .context(old: oldNext, new: newNext), text: ""))
                oldNext += 1
                newNext += 1
            }
        }
    }

    mutating func consumeHeader(_ line: Substring) {
        if line.hasPrefix("new file mode") {
            change = .added
        } else if line.hasPrefix("deleted file mode") {
            change = .deleted
        } else if let value = line.dropPrefix("similarity index ") {
            similarity = Int(value.dropLast()) ?? 0
        } else if let value = line.dropPrefix("rename from ") {
            oldPath = String(value)
        } else if let value = line.dropPrefix("rename to ") {
            path = String(value)
        } else if let value = line.dropPrefix("copy from ") {
            copiedFrom = String(value)
        } else if let value = line.dropPrefix("copy to ") {
            path = String(value)
        } else if let value = line.dropPrefix("--- ") {
            if let old = value.dropPrefix("a/") { oldPath = oldPath ?? String(old) }
        } else if let value = line.dropPrefix("+++ ") {
            if let new = value.dropPrefix("b/") { path = String(new) }
        } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
            isBinary = true
        }
    }

    mutating func startHunk(_ line: Substring) {
        inHeader = false
        let ranges = parseHunkRanges(line)
        oldNext = ranges.old
        newNext = ranges.new
        hunks.append(Hunk(header: String(line), oldStart: ranges.old, newStart: ranges.new, lines: []))
    }

    mutating func append(_ line: DiffLine) {
        hunks[hunks.count - 1].lines.append(line)
    }

    func finish() -> FileDiff {
        var resolved = change
        if change == .deleted, let oldPath {
            return FileDiff(path: oldPath, change: .deleted, isBinary: isBinary, hunks: hunks)
        }
        if let copiedFrom {
            resolved = .copied(from: copiedFrom, similarity: similarity)
        } else if let oldPath, oldPath != path, change == .modified {
            resolved = .renamed(from: oldPath, similarity: similarity)
        }
        return FileDiff(path: path, change: resolved, isBinary: isBinary, hunks: hunks)
    }
}

/// Splits on LF bytes only. Splitting a Swift String on "\n" would miss CRLF line endings,
/// because "\r\n" is a single Character; any trailing "\r" stays in the line's text.
private func splitLines(_ text: String) -> [Substring] {
    var lines = text.utf8.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { Substring($0) }
    if lines.last?.isEmpty == true { lines.removeLast() }
    return lines
}

/// Reads the starts from `@@ -a[,b] +c[,d] @@`. A start of 0 (empty side) still yields 0.
private func parseHunkRanges(_ line: Substring) -> (old: Int, new: Int) {
    let fields = line.split(separator: " ")
    func start(_ prefix: Character) -> Int {
        guard let field = fields.first(where: { $0.first == prefix }) else { return 0 }
        return Int(field.dropFirst().prefix { $0 != "," }) ?? 0
    }
    return (start("-"), start("+"))
}

private extension Substring {
    func dropPrefix(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}
