extension [CheckContext] {
    /// A line saying how the checks went, as GitHub's checks popover heads its list: "2 of 5
    /// checks failed". Nil when there are no checks.
    public var summary: String? {
        guard !isEmpty else { return nil }
        let failed = count { $0.status == .failure }
        let pending = count { $0.status == .pending }
        let passed = count { $0.status == .success }
        if failed > 0 { return "\(failed) of \(checks(count)) failed" }
        if pending == count { return "\(checks(count)) pending" }
        if pending > 0 { return "\(pending) of \(checks(count)) pending" }
        if passed == count { return count == 1 ? "1 check passed" : "All \(checks(count)) passed" }
        return "\(passed) of \(checks(count)) passed, \(count - passed) skipped"
    }

    /// The checks as GitHub's popover lists them: failing first, then pending, then the rest in
    /// GitHub's order.
    public var failingFirst: [CheckContext] {
        filter { $0.status == .failure } + filter { $0.status == .pending }
            + filter { $0.status != .failure && $0.status != .pending }
    }

    /// The failed checks' names without their integration's prefix ("build" for
    /// "ci/circleci: build"), so the header says which job to look at, which the glyph alone
    /// doesn't. Codecov's are left out: coverage failures are noise nobody acts on from there.
    public var failedCheckNames: [String] {
        filter { $0.status == .failure && !$0.name.lowercased().hasPrefix("codecov/") }
            .map { shortName($0.name) }
    }
}

private func checks(_ count: Int) -> String {
    count == 1 ? "1 check" : "\(count) checks"
}

/// What follows an integration's prefix: after the first ": ", else after the first "/".
private func shortName(_ name: String) -> String {
    let short = if let range = name.range(of: ": ") {
        name[range.upperBound...]
    } else if let slash = name.firstIndex(of: "/") {
        name[name.index(after: slash)...]
    } else {
        Substring(name)
    }
    return short.trimmingCharacters(in: .whitespaces)
}
