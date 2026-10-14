import CoreGraphics
import LoupeCore
import Testing

struct OverscrollTriggerTests {
    @Test func aDragPastTheThresholdFillsArmsAndFiresWhenLetGo() {
        var trigger = OverscrollTrigger(threshold: 80)
        trigger.beginDrag()
        #expect(trigger.scroll(overscroll: -200) == nil, "still within the document")
        #expect(trigger.progress == 0)
        #expect(trigger.scroll(overscroll: 40) == nil)
        #expect(trigger.progress == 0.5)
        #expect(trigger.scroll(overscroll: 80) == .armed)
        #expect(trigger.scroll(overscroll: 120) == nil, "armed once")
        #expect(trigger.progress == 1)

        #expect(trigger.endDrag() == .fired)
        #expect(trigger.progress == 0)
        #expect(trigger.scroll(overscroll: 60) == nil, "springing back after firing shows nothing")
        #expect(trigger.progress == 0)
    }

    @Test func lettingGoShortOfTheThresholdSnapsBackWithoutFiring() {
        var trigger = OverscrollTrigger(threshold: 80)
        trigger.beginDrag()
        _ = trigger.scroll(overscroll: 60)
        #expect(trigger.endDrag() == nil)
        #expect(trigger.progress == 0.75)

        _ = trigger.scroll(overscroll: 90)
        #expect(trigger.progress == 0.75, "an overshoot while springing back doesn't fill it")
        _ = trigger.scroll(overscroll: 20)
        #expect(trigger.progress == 0.25)
        _ = trigger.scroll(overscroll: 0)
        #expect(trigger.progress == 0)
        #expect(trigger.endDrag() == nil)
    }

    @Test func pullingBackUnderTheThresholdBeforeLettingGoDisarmsIt() {
        var trigger = OverscrollTrigger(threshold: 80)
        trigger.beginDrag()
        #expect(trigger.scroll(overscroll: 100) == .armed)
        #expect(trigger.scroll(overscroll: 50) == .disarmed)
        #expect(!trigger.isArmed)
        #expect(trigger.endDrag() == nil)
    }

    @Test func momentumBouncingPastTheEndNeverFillsOrFires() {
        var trigger = OverscrollTrigger(threshold: 80)
        // A fling: the fingers lift mid-document and momentum carries on past the end.
        trigger.beginDrag()
        _ = trigger.scroll(overscroll: -500)
        #expect(trigger.endDrag() == nil)
        _ = trigger.scroll(overscroll: -100)
        #expect(trigger.scroll(overscroll: 150) == nil)
        #expect(trigger.progress == 0)
        #expect(trigger.endDrag() == nil)

        // A second, live pull does count.
        trigger.beginDrag()
        #expect(trigger.scroll(overscroll: 90) == .armed)
        #expect(trigger.endDrag() == .fired)
    }
}
