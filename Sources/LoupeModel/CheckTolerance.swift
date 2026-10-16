import Foundation

extension CheckContext {
    /// Whether this is a failure that doesn't make the PR's checks fail: Codecov's project check,
    /// which fails on small drifts nobody acts on, or its patch check while the diff's coverage
    /// is at least `minimumDiffCoverage`. A patch check whose coverage can't be read still fails.
    public var isToleratedFailure: Bool {
        guard status == .failure else { return false }
        switch name.lowercased() {
        case "codecov/project": return true
        case "codecov/patch": return diffCoverage(description).map { $0 >= Self.minimumDiffCoverage } ?? false
        default: return false
        }
    }

    /// The share of a diff's lines, in percent, that must be covered for Codecov's patch check
    /// failing to count: below this the diff is worth a look.
    public static let minimumDiffCoverage = 70.0
}

extension CheckState {
    /// The state to show for a head commit whose rollup is this and whose checks are `contexts`:
    /// GitHub's, unless it failed only through tolerated failures, when it's pending while any
    /// check is and passed otherwise. Kept as it is when no failing check was fetched to tell.
    public func tolerating(_ contexts: [CheckContext]) -> CheckState {
        guard self == .failure || self == .error else { return self }
        let failures = contexts.filter { $0.status == .failure }
        guard !failures.isEmpty, failures.allSatisfy(\.isToleratedFailure) else { return self }
        return contexts.contains { $0.status == .pending } ? .pending : .success
    }
}

/// The leading percentage of a Codecov patch check's description, as in
/// "76.92% of diff hit (target 98.23%)".
private func diffCoverage(_ description: String?) -> Double? {
    guard let description, let percent = description.firstIndex(of: "%") else { return nil }
    return Double(description[..<percent].trimmingCharacters(in: .whitespaces))
}
