import Foundation

/// How a PR that's no longer open ended, and when, for the header's slot that holds the merge
/// button while it's open.
public struct PullRequestOutcome: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case merged
        case closed
    }

    public let kind: Kind
    /// Nil on rows stored before the time was fetched, until the next refresh.
    public let date: Date?

    /// Nil while the PR is open.
    public init?(_ pullRequest: PullRequestSummary) {
        switch pullRequest.state {
        case .merged:
            kind = .merged
            date = pullRequest.mergedAt
        case .closed:
            kind = .closed
            date = pullRequest.closedAt
        case .open, .unknown:
            return nil
        }
    }

    public var title: String {
        switch kind {
        case .merged: "Merged"
        case .closed: "Closed"
        }
    }

    /// Relative within the last week ("3 hours ago"), where that reads at a glance; beyond it a
    /// date and time ("14 Oct 2026 at 15:02"), as "4 weeks ago" is too vague to place.
    public func when(now: Date = .now, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String? {
        guard let date else { return nil }
        if now.timeIntervalSince(date) < recentInterval {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = locale
            formatter.dateTimeStyle = .named
            return formatter.localizedString(for: date, relativeTo: now)
        }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: locale, timeZone: timeZone))
    }

    /// The full date and time, for a tooltip, whichever way `when` puts it.
    public func help(locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        guard let date else { return title }
        return "\(title) \(date.formatted(Date.FormatStyle(date: .complete, time: .shortened, locale: locale, timeZone: timeZone)))"
    }
}

private let recentInterval: TimeInterval = 7 * 24 * 60 * 60
