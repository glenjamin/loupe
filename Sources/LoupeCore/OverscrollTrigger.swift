import CoreGraphics

/// Turns pulling past the end of a document into a deliberate action, like pull-to-refresh at
/// the bottom. Only a live drag, fingers still on the trackpad, fills it; it fires when that drag
/// ends past the threshold. Momentum bouncing off the end never fills or fires it.
public struct OverscrollTrigger: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// The drag has gone past the threshold, so letting go now fires.
        case armed
        /// The drag has come back under the threshold.
        case disarmed
        case fired
    }

    /// How far past the end a drag must go to fire.
    public let threshold: CGFloat
    /// How full the indicator is, from 0 to 1.
    public private(set) var progress: CGFloat = 0
    private var state = State.idle

    public init(threshold: CGFloat = 40) {
        self.threshold = threshold
    }

    /// Whether letting go now fires.
    public var isArmed: Bool {
        state == .dragging && progress >= 1
    }

    /// The fingers have touched down and started scrolling.
    public mutating func beginDrag() {
        state = .dragging
    }

    /// The document has scrolled to `overscroll` points past its end, or before it when not
    /// positive, by whatever means.
    public mutating func scroll(overscroll: CGFloat) -> Event? {
        let fill = min(max(overscroll / threshold, 0), 1)
        switch state {
        case .idle:
            progress = 0
            return nil
        case .settling:
            // Emptying as it springs back, without arming again.
            progress = min(progress, fill)
            if overscroll <= 0 { state = .idle }
            return nil
        case .dragging:
            let wasArmed = isArmed
            progress = fill
            return wasArmed == isArmed ? nil : (isArmed ? .armed : .disarmed)
        }
    }

    /// The fingers have lifted, or the gesture was cancelled.
    public mutating func endDrag() -> Event? {
        guard state == .dragging else { return nil }
        if isArmed {
            state = .idle
            progress = 0
            return .fired
        }
        state = .settling
        return nil
    }

    private enum State: Sendable, Equatable {
        case idle
        case dragging
        /// Let go short of the threshold, and springing back.
        case settling
    }
}
