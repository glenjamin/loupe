import CoreGraphics
import Foundation
import LoupeCore
import Testing

struct OverscrollTriggerTests {
    /// Finger travel past the end that arms a pull which started counting at the lead-in.
    static let armingTravel = OverscrollTrigger.leadIn + countedTravel
    /// Finger travel, once counting, that arms it.
    static let countedTravel = OverscrollTrigger.target / OverscrollTrigger.dragRate
    static let dwell = OverscrollTrigger.dwell

    @Test func aScrollRunningThroughTheEndNeverArms() {
        // A swipe reaching the end with the fingers still moving spends the rest of its travel
        // past it, far more than arms a deliberate pull, and lifts within the dwell.
        var fingers = Fingers()
        fingers.touchDown()
        fingers.pull(Self.armingTravel * 2, over: Self.dwell * 0.75)
        #expect(fingers.trigger.progress == 0)
        #expect(!fingers.trigger.isArmed)
        #expect(fingers.lift() == false)
        #expect(fingers.taps == 0)
    }

    @Test func travelDuringTheDwellIsSpent() {
        var fingers = Fingers()
        fingers.touchDown()
        fingers.pull(150, over: Self.dwell / 2)
        fingers.rest(Self.dwell)
        #expect(fingers.trigger.progress == 0, "holding past the end alone fills nothing")
        // Counting starts from where the fingers were when the dwell passed, not from the end.
        fingers.pull(Self.countedTravel - 2, over: 0.5)
        #expect(!fingers.trigger.isArmed)
        #expect(fingers.trigger.progress > 0.9)
        fingers.pull(4, over: 0.05)
        #expect(fingers.trigger.isArmed)
        #expect(fingers.taps == 1)
        #expect(fingers.lift() == true)
    }

    @Test func aSlowPullArmsAfterTheLeadInAndTheTargetAtHalfRate() {
        var fingers = Fingers()
        fingers.touchDown()
        // Slower than the dwell, so the lead-in is what holds it empty.
        fingers.pull(OverscrollTrigger.leadIn, over: Self.dwell * 1.5)
        #expect(fingers.trigger.progress < 0.001, "the lead-in never counts")
        fingers.pull(OverscrollTrigger.target, over: 0.3)
        #expect(abs(fingers.trigger.progress - OverscrollTrigger.dragRate) < 0.01, "counts at the drag rate")
        fingers.pull(Self.countedTravel - OverscrollTrigger.target - 2, over: 0.3)
        #expect(!fingers.trigger.isArmed, "just short of the lead-in plus the target")
        fingers.pull(4, over: 0.05)
        #expect(fingers.trigger.isArmed)
        #expect(fingers.trigger.progress == 1)
        #expect(fingers.lift() == true, "fires when the fingers lift")
        #expect(fingers.trigger.progress == 0)
        #expect(!fingers.trigger.isDragging)
    }

    @Test func itTapsOnceAtTheMomentItArms() {
        var fingers = Fingers()
        fingers.touchDown()
        fingers.holdPastTheEnd()
        fingers.pull(Self.countedTravel + 2, over: 0.3)
        #expect(fingers.taps == 1)
        fingers.pull(100, over: 0.2)
        #expect(fingers.taps == 1, "pulling further doesn't tap again")
        #expect(fingers.trigger.progress == 1, "progress stops at full")
        #expect(fingers.lift() == true)
    }

    @Test func pullingBackUnderTheTargetDisarms() {
        var fingers = Fingers()
        fingers.touchDown()
        fingers.holdPastTheEnd()
        fingers.pull(Self.countedTravel + 10, over: 0.3)
        #expect(fingers.trigger.isArmed)
        fingers.pull(-30, over: 0.1)
        #expect(!fingers.trigger.isArmed)
        #expect(fingers.trigger.progress > 0 && fingers.trigger.progress < 1)
        fingers.pull(30, over: 0.1)
        #expect(fingers.trigger.isArmed, "pulling out again re-arms")
        #expect(fingers.taps == 2, "with another tap")

        // Pulled all the way back to the end, the next pull starts over, dwell and all.
        fingers.pull(-1000, over: 0.2)
        #expect(fingers.trigger.progress == 0)
        fingers.pull(Self.armingTravel * 2, over: Self.dwell * 0.75)
        #expect(!fingers.trigger.isArmed)
        #expect(fingers.lift() == false)
    }

    @Test func lettingGoShortOfTheTargetDoesNothing() {
        var fingers = Fingers()
        fingers.touchDown()
        fingers.holdPastTheEnd()
        fingers.pull(Self.countedTravel - 2, over: 0.3)
        #expect(fingers.trigger.progress > 0.9)
        #expect(fingers.lift() == false)
        #expect(fingers.trigger.progress == 0, "empties as the rubber band springs back")
    }

    @Test func momentumAfterTheFingersLiftNeverFillsArmsOrFires() {
        // A fling: the fingers lift mid-document and momentum carries on past the end.
        var fingers = Fingers()
        fingers.touchDown()
        #expect(fingers.lift() == false)
        fingers.pull(Self.armingTravel * 2, over: 1)
        #expect(fingers.trigger.progress == 0)
        #expect(!fingers.trigger.isArmed)
        #expect(fingers.lift() == false)
        #expect(fingers.taps == 0)

        // Nor does scrolling with no drag at all, as a mouse wheel does.
        var wheel = Fingers()
        wheel.pull(Self.armingTravel * 2, over: 1)
        #expect(wheel.trigger.progress == 0)
        #expect(wheel.lift() == false)
    }

    @Test func cancellingTheGestureDisarmsWithoutFiring() {
        var fingers = Fingers()
        fingers.touchDown()
        fingers.holdPastTheEnd()
        fingers.pull(Self.countedTravel + 10, over: 0.3)
        #expect(fingers.trigger.isArmed)
        fingers.trigger.cancelDrag()
        #expect(!fingers.trigger.isArmed)
        #expect(fingers.trigger.progress == 0)
        #expect(fingers.lift() == false, "a lift after the cancel doesn't fire")
    }

    @Test func itFiresOncePerGesture() {
        var fingers = Fingers()
        fingers.touchDown()
        fingers.holdPastTheEnd()
        fingers.pull(Self.countedTravel + 10, over: 0.3)
        #expect(fingers.lift() == true)
        #expect(fingers.lift() == false, "a second lift without a new drag doesn't fire again")

        fingers.touchDown()
        #expect(fingers.lift() == false, "a new drag starts empty")
        fingers.touchDown()
        fingers.pull(Self.armingTravel * 2, over: Self.dwell * 0.75)
        #expect(!fingers.trigger.isArmed, "and has to dwell again")
        fingers.rest(Self.dwell)
        fingers.pull(Self.countedTravel + 2, over: 0.3)
        #expect(fingers.lift() == true, "before a full pull fires it again")
    }
}

/// Drives a trigger as a trackpad does: an event every frame while the fingers move, each with
/// its share of the travel, and none while they rest.
private struct Fingers {
    static let frame: TimeInterval = 1.0 / 120

    var trigger = OverscrollTrigger()
    /// Times are since boot, as `NSEvent.timestamp` is.
    var time: TimeInterval = 1000
    /// Haptic taps so far.
    var taps = 0

    mutating func touchDown() {
        trigger.beginDrag()
    }

    mutating func pull(_ distance: CGFloat, over duration: TimeInterval) {
        let steps = max(1, Int((duration / Self.frame).rounded()))
        for _ in 0..<steps {
            time += duration / Double(steps)
            if trigger.pull(by: distance / CGFloat(steps), at: time) { taps += 1 }
        }
    }

    /// Eases past the end through the lead-in, slowly enough that the dwell passes on the way, so
    /// what's pulled next counts in full.
    mutating func holdPastTheEnd() {
        pull(OverscrollTrigger.leadIn, over: OverscrollTrigger.dwell * 1.5)
    }

    mutating func rest(_ duration: TimeInterval) {
        time += duration
    }

    mutating func lift() -> Bool {
        trigger.endDrag()
    }
}
