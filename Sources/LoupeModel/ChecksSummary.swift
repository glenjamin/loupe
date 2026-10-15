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
}

private func checks(_ count: Int) -> String {
    count == 1 ? "1 check" : "\(count) checks"
}
