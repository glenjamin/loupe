import CoreGraphics
import Foundation

/// Turns pulling past the end of a document into a deliberate action, pull-to-refresh at the
/// bottom. Progress is how far the fingers have travelled past the end, not how far the rubber
/// band stretched, which AppKit damps. The start of each pull is free: travel counts only once
/// the fingers have been past the end for a while and beyond a lead-in, so a scroll that runs
/// into the end and spends its remaining travel there never arms. A drag that begins with the
/// view already at its end has no such scroll behind it, so only the lead-in applies, and a quick
/// deliberate pull from rest counts straight away. Crossing the target arms it,
/// pulling back under disarms it, and lifting the fingers while armed fires it. Only a live
/// drag counts, so momentum carrying on past the end never fills, arms or fires it.
public struct OverscrollTrigger: Sendable, Equatable {
    /// How long the fingers must have been past the end, within one drag that reached it while
    /// scrolling, before any travel counts. Longer than the tail of a scroll that runs into the
    /// end.
    public static let dwell: TimeInterval = 0.2
    /// Finger travel past the end that never counts, like a touch slop.
    public static let leadIn: CGFloat = 40
    /// How much of the counted finger travel goes towards the target, as SwipeRefreshLayout's
    /// `DRAG_RATE`, so the fill keeps to about the pace of the damped rubber band.
    public static let dragRate: CGFloat = 0.5
    /// The counted distance that arms it, SwipeRefreshLayout's default; at `dragRate` that takes
    /// twice as much finger travel.
    public static let target: CGFloat = 64

    /// Whether the fingers are down, scrolling.
    public private(set) var isDragging = false
    /// How far the fingers have pulled past the end in this drag, never below zero.
    private var travel: CGFloat = 0
    /// When this drag's fingers went past the end, while they're still past it.
    private var pastEndSince: TimeInterval?
    /// The travel from which pulling counts, once the dwell has passed.
    private var countsFrom: CGFloat?
    /// Whether this drag began at the end and hasn't since gone back from it, so it needn't dwell.
    private var beganAtEnd = false

    public init() {}

    /// The distance counted towards the target, after the dwell and lead-in and at the drag rate.
    public var pulled: CGFloat {
        guard let countsFrom else { return 0 }
        return max(0, travel - countsFrom) * Self.dragRate
    }

    /// How full the indicator is, from 0 to 1; empty through the dwell and lead-in.
    public var progress: CGFloat {
        min(pulled / Self.target, 1)
    }

    /// Whether lifting the fingers now would fire it.
    public var isArmed: Bool {
        isDragging && pulled >= Self.target
    }

    /// The fingers have touched down and started scrolling, with the document `atEnd` or not.
    public mutating func beginDrag(atEnd: Bool) {
        reset()
        isDragging = true
        beganAtEnd = atEnd
    }

    /// The fingers moved `distance` points at `time` with the document at its end: positive pulls
    /// the content further past the end, negative pulls it back. Returns true at the moment it
    /// arms, for a haptic tap.
    public mutating func pull(by distance: CGFloat, at time: TimeInterval) -> Bool {
        guard isDragging else { return false }
        let wasArmed = isArmed
        if beganAtEnd {
            countsFrom = countsFrom ?? Self.leadIn
        } else if let since = pastEndSince {
            // Whatever was travelled during the dwell is spent, so it can't count later.
            if countsFrom == nil, time - since >= Self.dwell {
                countsFrom = max(Self.leadIn, travel)
            }
        } else {
            pastEndSince = time
        }
        travel = max(0, travel + distance)
        // Back at the end, the next pull past it has to dwell again.
        if travel == 0 {
            pastEndSince = nil
            countsFrom = nil
            if distance < 0 { beganAtEnd = false }
        }
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
        pastEndSince = nil
        countsFrom = nil
        beganAtEnd = false
    }
}
