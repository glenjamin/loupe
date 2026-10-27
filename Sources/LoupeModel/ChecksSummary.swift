extension [CheckContext] {
    /// A line saying how the checks went, as GitHub's checks popover heads its list: "2 of 5
    /// checks failed". Tolerated failures aren't counted as failed but named as ignored. Nil
    /// when there are no checks.
    public var summary: String? {
        guard !isEmpty else { return nil }
        let failed = count { $0.status == .failure && !$0.isToleratedFailure }
        let tolerated = count(where: \.isToleratedFailure)
        let pending = count { $0.status == .pending }
        let passed = count { $0.status == .success }
        if failed > 0 { return "\(failed) of \(checks(count)) failed" }
        if pending == count { return "\(checks(count)) pending" }
        if pending > 0 { return "\(pending) of \(checks(count)) pending" }
        if passed == count { return count == 1 ? "1 check passed" : "All \(checks(count)) passed" }
        let skipped = count - passed - tolerated
        return (["\(passed) of \(checks(count)) passed"]
            + (skipped > 0 ? ["\(skipped) skipped"] : [])
            + (tolerated > 0 ? [tolerated == 1 ? "1 coverage failure ignored" : "\(tolerated) coverage failures ignored"] : []))
            .joined(separator: ", ")
    }

    /// The checks as GitHub's popover lists them: failing first, then pending, then tolerated
    /// failures, then the rest in GitHub's order.
    public var failingFirst: [CheckContext] {
        let failing = filter { $0.status == .failure && !$0.isToleratedFailure }
        let pending = filter { $0.status == .pending }
        let tolerated = filter(\.isToleratedFailure)
        let rest = filter { $0.status != .failure && $0.status != .pending }
        return failing + pending + tolerated + rest
    }

    /// The failed checks' names without their integration's prefix ("build" for
    /// "ci/circleci: build"), so the header says which job to look at, which the glyph alone
    /// doesn't. Tolerated failures are left out, as they don't make the checks fail.
    public var failedCheckNames: [String] {
        filter { $0.status == .failure && !$0.isToleratedFailure }
            .map { shortName($0.name) }
    }
}

private func checks(_ count: Int) -> String {
    count == 1 ? "1 check" : "\(count) checks"
}

/// What follows an integration's prefix: after the first ": ", else after the first "/".
func shortName(_ name: String) -> String {
    let short = if let range = name.range(of: ": ") {
        name[range.upperBound...]
    } else if let slash = name.firstIndex(of: "/") {
        name[name.index(after: slash)...]
    } else {
        Substring(name)
    }
    return short.trimmingCharacters(in: .whitespaces)
}
