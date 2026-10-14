import CoreGraphics
import LoupeCore
import Testing

struct OverscrollTriggerTests {
    @Test func aDragPastTheThresholdFillsArmsAndFiresWhenLetGo() {
        var trigger = OverscrollTrigger()
        // Short, as the footer's button is the main way and this a shortcut.
        #expect(trigger.threshold == 40)
        trigger.beginDrag()
        #expect(trigger.scroll(overscroll: -100) == nil, "still within the document")
        #expect(trigger.progress == 0)
        #expect(trigger.scroll(overscroll: 20) == nil)
        #expect(trigger.progress == 0.5)
        #expect(trigger.scroll(overscroll: 40) == .armed)
        #expect(trigger.scroll(overscroll: 60) == nil, "armed once")
        #expect(trigger.progress == 1)

        #expect(trigger.endDrag() == .fired)
        #expect(trigger.progress == 0)
        #expect(trigger.scroll(overscroll: 30) == nil, "springing back after firing shows nothing")
        #expect(trigger.progress == 0)
    }

    @Test func lettingGoShortOfTheThresholdSnapsBackWithoutFiring() {
        var trigger = OverscrollTrigger()
        trigger.beginDrag()
        _ = trigger.scroll(overscroll: 30)
        #expect(trigger.endDrag() == nil)
        #expect(trigger.progress == 0.75)

        _ = trigger.scroll(overscroll: 45)
        #expect(trigger.progress == 0.75, "an overshoot while springing back doesn't fill it")
        _ = trigger.scroll(overscroll: 10)
        #expect(trigger.progress == 0.25)
        _ = trigger.scroll(overscroll: 0)
        #expect(trigger.progress == 0)
        #expect(trigger.endDrag() == nil)
    }

    @Test func pullingBackUnderTheThresholdBeforeLettingGoDisarmsIt() {
        var trigger = OverscrollTrigger()
        trigger.beginDrag()
        #expect(trigger.scroll(overscroll: 50) == .armed)
        #expect(trigger.scroll(overscroll: 25) == .disarmed)
        #expect(!trigger.isArmed)
        #expect(trigger.endDrag() == nil)
    }

    @Test func momentumBouncingPastTheEndNeverFillsOrFires() {
        var trigger = OverscrollTrigger()
        // A fling: the fingers lift mid-document and momentum carries on past the end.
        trigger.beginDrag()
        _ = trigger.scroll(overscroll: -250)
        #expect(trigger.endDrag() == nil)
        _ = trigger.scroll(overscroll: -50)
        #expect(trigger.scroll(overscroll: 75) == nil)
        #expect(trigger.progress == 0)
        #expect(trigger.endDrag() == nil)

        // A second, live pull does count.
        trigger.beginDrag()
        #expect(trigger.scroll(overscroll: 45) == .armed)
        #expect(trigger.endDrag() == .fired)
    }
}
