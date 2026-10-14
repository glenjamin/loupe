import CoreGraphics
import LoupeCore
import Testing

struct OverscrollTriggerTests {
    @Test func aDragFillsAndFiresTheMomentItCrossesTheThreshold() {
        var trigger = OverscrollTrigger()
        // Short, as pulling past the end is unresisted scrolling and a shortcut for the button.
        #expect(trigger.threshold == 32)
        trigger.beginDrag()
        #expect(trigger.scroll(overscroll: -100) == false, "still within the document")
        #expect(trigger.progress == 0)
        #expect(trigger.scroll(overscroll: 16) == false)
        #expect(trigger.progress == 0.5)
        #expect(trigger.scroll(overscroll: 32) == true, "fires without waiting for the fingers to lift")
        #expect(trigger.hasFired)
        #expect(trigger.progress == 1)
    }

    @Test func itFiresOnceAndStaysSpentUntilTheDocumentSettlesBackToItsEnd() {
        var trigger = OverscrollTrigger()
        trigger.beginDrag()
        #expect(trigger.scroll(overscroll: 40) == true)
        #expect(trigger.scroll(overscroll: 20) == false)
        #expect(trigger.scroll(overscroll: 50) == false, "the same drag going on doesn't fire again")
        trigger.endDrag()

        // Still sitting past the end, as when the last file stays shown.
        trigger.beginDrag()
        #expect(trigger.scroll(overscroll: 60) == false, "a new drag before settling back doesn't fire")
        trigger.endDrag()
        #expect(trigger.scroll(overscroll: 0) == false)
        #expect(!trigger.hasFired)
        #expect(trigger.progress == 0)

        trigger.beginDrag()
        #expect(trigger.scroll(overscroll: 32) == true, "settled back, so a new pull counts")
    }

    @Test func lettingGoShortOfTheThresholdEmptiesAsItSettlesBack() {
        var trigger = OverscrollTrigger()
        trigger.beginDrag()
        _ = trigger.scroll(overscroll: 24)
        trigger.endDrag()
        #expect(trigger.progress == 0.75)

        #expect(trigger.scroll(overscroll: 40) == false, "momentum carrying on doesn't fill or fire it")
        #expect(trigger.progress == 0.75)
        _ = trigger.scroll(overscroll: 8)
        #expect(trigger.progress == 0.25)
        _ = trigger.scroll(overscroll: 0)
        #expect(trigger.progress == 0)
    }

    @Test func momentumPastTheEndNeverFillsOrFires() {
        var trigger = OverscrollTrigger()
        // A fling: the fingers lift mid-document and momentum carries on past the end.
        trigger.beginDrag()
        _ = trigger.scroll(overscroll: -250)
        trigger.endDrag()
        _ = trigger.scroll(overscroll: -50)
        #expect(trigger.scroll(overscroll: 64) == false)
        #expect(trigger.progress == 0)

        // Nor does scrolling with no drag at all, as a mouse wheel does.
        var wheel = OverscrollTrigger()
        #expect(wheel.scroll(overscroll: 64) == false)
        #expect(wheel.progress == 0)
    }
}
