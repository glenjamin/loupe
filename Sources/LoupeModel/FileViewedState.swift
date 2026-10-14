/// Whether the viewer has marked a PR's file as viewed, as github.com's "Viewed" checkbox does.
public enum FileViewedState: String, Sendable, LenientEnum {
    case viewed = "VIEWED"
    case unviewed = "UNVIEWED"
    /// Viewed, then changed by a later push, so due another look.
    case dismissed = "DISMISSED"
    case unknown

    /// Only a file still viewed as it is now counts; one changed since needs reviewing again.
    public var isViewed: Bool {
        self == .viewed
    }
}
