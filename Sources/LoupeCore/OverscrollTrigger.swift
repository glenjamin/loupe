import CoreGraphics

/// Turns pulling past the end of a document into a deliberate action, pull-to-refresh at the
/// bottom. Progress is how far the fingers have travelled since the document reached its end,
/// not how far the rubber band stretched, which AppKit damps. Crossing the threshold arms it,
/// pulling back under disarms it, and lifting the fingers while armed fires it. Only a live
/// drag counts, so momentum carrying on past the end never fills, arms or fires it.
public struct OverscrollTrigger: Sendable, Equatable {
    /// Finger travel past the end that arms it, the usual pull-to-refresh distance.
    public static let pullDistance: CGFloat = 80

    public let threshold: CGFloat
    /// How far the fingers have pulled past the end in this drag, never below zero.
    public private(set) var travel: CGFloat = 0
    /// Whether the fingers are down, scrolling.
    public private(set) var isDragging = false

    public init(threshold: CGFloat = Self.pullDistance) {
        self.threshold = threshold
    }

    /// How full the indicator is, from 0 to 1.
    public var progress: CGFloat {
        min(travel / threshold, 1)
    }

    /// Whether lifting the fingers now would fire it.
    public var isArmed: Bool {
        isDragging && travel >= threshold
    }

    /// The fingers have touched down and started scrolling.
    public mutating func beginDrag() {
        isDragging = true
        travel = 0
    }

    /// The fingers moved `distance` points with the document at its end: positive pulls the
    /// content further past the end, negative pulls it back. Returns true at the moment it arms,
    /// for a haptic tap.
    public mutating func pull(by distance: CGFloat) -> Bool {
        guard isDragging else { return false }
        let wasArmed = isArmed
        travel = max(0, travel + distance)
        return isArmed && !wasArmed
    }

    /// The fingers have lifted. Returns true if it was armed, and so fires.
    public mutating func endDrag() -> Bool {
        let fires = isArmed
        reset()
        return fires
    }

    /// The gesture was cancelled, which never fires.
    public mutating func cancelDrag() {
        reset()
    }

    private mutating func reset() {
        isDragging = false
        travel = 0
    }
}
