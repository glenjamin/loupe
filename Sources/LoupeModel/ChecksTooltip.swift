extension [CheckContext] {
    /// A summary like GitHub's checks popover: a line saying how the checks went, then one line
    /// per check, failing first, then pending, then the rest in GitHub's order. Nil when there
    /// are no checks to list.
    public var tooltip: String? {
        guard !isEmpty else { return nil }
        let failing = filter { $0.status == .failure }
        let pending = filter { $0.status == .pending }
        let rest = filter { $0.status != .failure && $0.status != .pending }
        return ([summary] + (failing + pending + rest).map(\.line)).joined(separator: "\n")
    }

    private var summary: String {
        let failed = count { $0.status == .failure }
        let pending = count { $0.status == .pending }
        let passed = count { $0.status == .success }
        if failed > 0 { return "\(failed) of \(checks(count)) failed" }
        if pending == count { return "\(checks(count)) pending" }
        if pending > 0 { return "\(pending) of \(checks(count)) pending" }
        if passed == count { return count == 1 ? "1 check passed" : "All \(checks(count)) passed" }
        return "\(passed) of \(checks(count)) passed, \(count - passed) skipped"
    }
}

private extension CheckContext {
    var line: String {
        let line = "\(status.glyph) \(name)"
        guard let description, !description.isEmpty else { return line }
        return "\(line) — \(description)"
    }
}

private extension CheckStatus {
    var glyph: String {
        switch self {
        case .success: "✓"
        case .failure: "✗"
        case .pending: "●"
        case .neutral: "–"
        }
    }
}

private func checks(_ count: Int) -> String {
    count == 1 ? "1 check" : "\(count) checks"
}
