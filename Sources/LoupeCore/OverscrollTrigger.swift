import CoreGraphics

/// Turns pulling past the end of a document into a deliberate action, like pull-to-refresh at
/// the bottom. Only a live drag, fingers still on the trackpad, fills it, and it fires the moment
/// that drag crosses the threshold. Momentum carrying on past the end never fills or fires it.
/// Once fired it stays spent until the document settles back to its end.
public struct OverscrollTrigger: Sendable, Equatable {
    /// How far past the end a drag must go to fire.
    public let threshold: CGFloat
    /// How full the indicator is, from 0 to 1.
    public private(set) var progress: CGFloat = 0
    private var state = State.idle

    public init(threshold: CGFloat = 32) {
        self.threshold = threshold
    }

    /// Whether it has fired and the document hasn't yet settled back to its end.
    public var hasFired: Bool {
        state == .fired
    }

    /// The fingers have touched down and started scrolling.
    public mutating func beginDrag() {
        guard state != .fired else { return }
        state = .dragging
    }

    /// The document has scrolled to `overscroll` points past its end, or before it when not
    /// positive, by whatever means. Returns true at the moment it fires.
    public mutating func scroll(overscroll: CGFloat) -> Bool {
        let fill = min(max(overscroll / threshold, 0), 1)
        switch state {
        case .idle:
            progress = 0
            return false
        case .settling, .fired:
            // Emptying as it settles back, without filling or firing again.
            progress = min(progress, fill)
            if overscroll <= 0 { state = .idle }
            return false
        case .dragging:
            progress = fill
            guard fill >= 1 else { return false }
            state = .fired
            return true
        }
    }

    /// The fingers have lifted, or the gesture was cancelled.
    public mutating func endDrag() {
        guard state == .dragging else { return }
        state = .settling
    }

    private enum State: Sendable, Equatable {
        case idle
        case dragging
        /// Let go short of the threshold, and settling back.
        case settling
        case fired
    }
}
