/// One changed file using another, or accompanying it, and why.
public struct DependencyLink: Sendable, Hashable {
    public enum Reason: Sendable, Hashable, Comparable {
        /// It imports, requires or includes the other.
        case imports
        /// It names something the other defines.
        case names
        /// It names the other's path in a string, as a test does its fixture.
        case path
        /// A framework's convention ties them, as Rails' does a view to its controller.
        case convention
        /// It declares the other's types, as `x.d.ts` does `x.js`.
        case declares
        /// It's a story of the other, as `x.stories.tsx` is of `x.tsx`.
        case story
        /// It tests the other.
        case tests
        /// It's a README about the other, beside it.
        case describes
        /// They're files of one small module, as a Terraform directory's are, so read together
        /// though neither uses the other. It groups them without ordering them.
        case module

        /// Whether the file goes with the other wherever that's listed, rather than being
        /// ordered by its use of it.
        public var isCompanion: Bool {
            self == .declares || self == .story || self == .tests
        }
    }

    public let from: String
    public let to: String
    public let reason: Reason

    public init(from: String, to: String, reason: Reason) {
        self.from = from
        self.to = to
        self.reason = reason
    }
}
