import CoreGraphics
import LoupeCore
import Testing

struct OverscrollTriggerTests {
    @Test func aPullArmsAtTheThresholdWithOneTapAndFiresOnRelease() {
        var trigger = OverscrollTrigger()
        #expect(trigger.threshold == OverscrollTrigger.pullDistance)
        trigger.beginDrag()
        #expect(trigger.pull(by: 40) == false)
        #expect(trigger.progress == 0.5)
        #expect(!trigger.isArmed)
        #expect(trigger.pull(by: 40) == true, "arms, with a tap, as it reaches the threshold")
        #expect(trigger.isArmed)
        #expect(trigger.progress == 1)
        #expect(trigger.pull(by: 30) == false, "pulling further doesn't tap again")
        #expect(trigger.progress == 1, "progress stops at full")
        #expect(trigger.endDrag() == true, "fires when the fingers lift")
        #expect(trigger.progress == 0)
        #expect(!trigger.isDragging)
    }

    @Test func pullingBackUnderTheThresholdDisarms() {
        var trigger = OverscrollTrigger()
        trigger.beginDrag()
        #expect(trigger.pull(by: 90) == true)
        #expect(trigger.pull(by: -30) == false)
        #expect(!trigger.isArmed)
        #expect(trigger.progress == 0.75)
        #expect(trigger.pull(by: -200) == false)
        #expect(trigger.progress == 0, "travel can't go below zero")
        #expect(trigger.pull(by: 40) == false)
        #expect(trigger.progress == 0.5, "pulling again counts from zero, not from below it")
        #expect(trigger.endDrag() == false)
    }

    @Test func lettingGoShortOfTheThresholdDoesNothing() {
        var trigger = OverscrollTrigger()
        trigger.beginDrag()
        _ = trigger.pull(by: 79)
        #expect(trigger.endDrag() == false)
        #expect(trigger.progress == 0, "empties as the rubber band springs back")
    }

    @Test func momentumAfterTheFingersLiftNeverFillsArmsOrFires() {
        var trigger = OverscrollTrigger()
        // A fling: the fingers lift mid-document and momentum carries on past the end.
        trigger.beginDrag()
        #expect(trigger.endDrag() == false)
        #expect(trigger.pull(by: 200) == false)
        #expect(trigger.progress == 0)
        #expect(!trigger.isArmed)
        #expect(trigger.endDrag() == false)

        // Nor does scrolling with no drag at all, as a mouse wheel does.
        var wheel = OverscrollTrigger()
        #expect(wheel.pull(by: 200) == false)
        #expect(wheel.progress == 0)
    }

    @Test func cancellingTheGestureDisarmsWithoutFiring() {
        var trigger = OverscrollTrigger()
        trigger.beginDrag()
        _ = trigger.pull(by: 100)
        trigger.cancelDrag()
        #expect(!trigger.isArmed)
        #expect(trigger.progress == 0)
        #expect(trigger.endDrag() == false, "a lift after the cancel doesn't fire")
    }

    @Test func itFiresOncePerGesture() {
        var trigger = OverscrollTrigger()
        trigger.beginDrag()
        _ = trigger.pull(by: 100)
        #expect(trigger.endDrag() == true)
        #expect(trigger.endDrag() == false, "a second lift without a new drag doesn't fire again")

        trigger.beginDrag()
        #expect(trigger.endDrag() == false, "a new drag starts empty")
        trigger.beginDrag()
        #expect(trigger.pull(by: 80) == true, "and a new full pull arms again")
        #expect(trigger.endDrag() == true)
    }
}
