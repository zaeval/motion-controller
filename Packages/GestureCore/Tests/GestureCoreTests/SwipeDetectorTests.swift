import Foundation
import Testing
@testable import GestureCore

struct SwipeDetectorTests {
    private static let frame = 1.0 / 30
    /// A swipe fires once its run has ended and its grace has run out, so every test has to keep the camera running
    /// past the stroke the way the app does.
    private static let tail: TimeInterval = 0.7

    /// Moves the anchor linearly, then holds it where it stopped for `tail`, and returns every swipe that fired.
    /// Pass `tail: 0` to chain another motion straight on instead.
    private func sweep(
        _ detector: inout SwipeDetector,
        from start: Vec2,
        to end: Vec2,
        seconds: TimeInterval,
        startingAt t0: TimeInterval,
        flat: (Int) -> Bool = { _ in true },
        pinching: Bool = false,
        dropFrames: Set<Int> = [],
        tail: TimeInterval = SwipeDetectorTests.tail
    ) -> [SwipeDirection] {
        let frames = Int((seconds / Self.frame).rounded())
        let held = Int((tail / Self.frame).rounded())
        var fired: [SwipeDirection] = []
        for index in 0...(frames + held) {
            let progress = Double(min(index, frames)) / Double(frames)
            let time = t0 + Double(index) * Self.frame
            let sample = dropFrames.contains(index) ? nil : SwipeDetector.Sample(
                anchor: start + (end - start) * progress,
                flatHand: flat(index),
                pinching: pinching,
                imageAspect: 1
            )
            if let direction = detector.update(sample, at: time) { fired.append(direction) }
        }
        return fired
    }

    @Test func handMovingTowardImageRightIsTheUsersLeft() {
        var detector = SwipeDetector()
        #expect(sweep(&detector, from: Vec2(0.3, 0.6), to: Vec2(0.6, 0.6), seconds: 0.3, startingAt: 0) == [.left])
    }

    @Test func swipeFromAStillHandFires() {
        var detector = SwipeDetector()
        #expect(sweep(&detector, from: Vec2(0.3, 0.45), to: Vec2(0.3, 0.45), seconds: 0.8, startingAt: 0, tail: 0).isEmpty)
        #expect(sweep(&detector, from: Vec2(0.3, 0.45), to: Vec2(0.4, 0.45), seconds: 0.2, startingAt: 0.8 + Self.frame) == [.left])
    }

    @Test func swipeArcingDownwardFires() {
        var detector = SwipeDetector()
        // Toward the user's right while dropping, the shape recorded swipes have.
        #expect(sweep(&detector, from: Vec2(0.40, 0.45), to: Vec2(0.28, 0.38), seconds: 0.25, startingAt: 0) == [.right])
    }

    /// The fix for a third of the user's recorded swipes switching the wrong desktop.
    @Test func theStrokeAfterAWindUpWins() {
        var detector = SwipeDetector()
        // Every recorded swipe starts with a small wind-up the other way, and the wind-up qualifies first.
        var fired = sweep(&detector, from: Vec2(0.40, 0.6), to: Vec2(0.33, 0.6), seconds: 0.3, startingAt: 0, tail: 0)
        fired += sweep(&detector, from: Vec2(0.33, 0.6), to: Vec2(0.63, 0.6), seconds: 0.3, startingAt: 0.3 + Self.frame)
        #expect(fired == [.left])
    }

    /// A wind-up as long as the stroke is a stroke in its own right, so the stroke has to clearly beat it.
    @Test func aStrokeSizedFirstMotionIsNotTreatedAsAWindUp() {
        var detector = SwipeDetector()
        var fired = sweep(&detector, from: Vec2(0.60, 0.6), to: Vec2(0.30, 0.6), seconds: 0.3, startingAt: 0, tail: 0)
        // Coming back almost as far is the return stroke, not a bigger swipe the other way.
        fired += sweep(&detector, from: Vec2(0.30, 0.6), to: Vec2(0.62, 0.6), seconds: 0.3, startingAt: 0.35)
        #expect(fired == [.right])
    }

    @Test func returnStrokeDoesNotFireTheOppositeSwipe() {
        var detector = SwipeDetector()
        var fired = sweep(&detector, from: Vec2(0.3, 0.6), to: Vec2(0.6, 0.6), seconds: 0.3, startingAt: 0, tail: 0)
        fired += sweep(&detector, from: Vec2(0.6, 0.6), to: Vec2(0.3, 0.6), seconds: 0.3, startingAt: 0.45)
        #expect(fired == [.left])
        // Long enough afterwards, the other way is meant.
        #expect(sweep(&detector, from: Vec2(0.6, 0.6), to: Vec2(0.3, 0.6), seconds: 0.3, startingAt: 3.0) == [.right])
    }

    @Test func swipingTheSameWayTwiceFiresTwice() {
        var detector = SwipeDetector()
        var fired = sweep(&detector, from: Vec2(0.30, 0.6), to: Vec2(0.60, 0.6), seconds: 0.3, startingAt: 0, tail: 0)
        // The hand comes back to swipe again; the return itself is suppressed.
        fired += sweep(&detector, from: Vec2(0.60, 0.6), to: Vec2(0.30, 0.6), seconds: 0.3, startingAt: 0.35, tail: 0)
        fired += sweep(&detector, from: Vec2(0.30, 0.6), to: Vec2(0.60, 0.6), seconds: 0.3, startingAt: 0.7)
        #expect(fired == [.left, .left])
    }

    @Test func aSecondStrokeWithoutAReturnIsNotASecondSwipe() {
        var detector = SwipeDetector()
        var fired = sweep(&detector, from: Vec2(0.30, 0.6), to: Vec2(0.60, 0.6), seconds: 0.3, startingAt: 0, tail: 0)
        // Drifting back too slowly to be a stroke, then the same way again: one recorded single swipe fired twice.
        fired += sweep(&detector, from: Vec2(0.60, 0.6), to: Vec2(0.30, 0.6), seconds: 2.5, startingAt: 0.35, tail: 0)
        fired += sweep(&detector, from: Vec2(0.30, 0.6), to: Vec2(0.60, 0.6), seconds: 0.3, startingAt: 2.9)
        #expect(fired == [.left])
    }

    @Test func slowDriftAndVerticalMotionDoNotFire() {
        var detector = SwipeDetector()
        #expect(sweep(&detector, from: Vec2(0.30, 0.6), to: Vec2(0.40, 0.6), seconds: 1.5, startingAt: 0).isEmpty)
        #expect(sweep(&detector, from: Vec2(0.5, 0.4), to: Vec2(0.55, 0.8), seconds: 0.3, startingAt: 5).isEmpty)
    }

    @Test func onlyAFlatHandSwipes() {
        var detector = SwipeDetector()
        // A pointing or folded hand crossing the frame is a cursor move or a parking gesture, not a swipe.
        #expect(sweep(&detector, from: Vec2(0.3, 0.6), to: Vec2(0.6, 0.6), seconds: 0.3, startingAt: 0, flat: { _ in false }).isEmpty)
        // Recorded swipes turn the palm away at the end, so the shape only has to hold for a few frames in a row.
        #expect(sweep(&detector, from: Vec2(0.3, 0.6), to: Vec2(0.6, 0.6), seconds: 0.3, startingAt: 5, flat: { $0 < 4 }) == [.left])
        // Fingers that only flicker into shape are mistracking, not a swipe.
        #expect(sweep(&detector, from: Vec2(0.3, 0.6), to: Vec2(0.6, 0.6), seconds: 0.3, startingAt: 10, flat: { $0 % 3 == 0 }).isEmpty)
    }

    @Test func aGentleSwipeStillFires() {
        var detector = SwipeDetector()
        // The gentlest recorded swipe that has to fire: 0.076 of the frame in a fifth of a second.
        #expect(sweep(&detector, from: Vec2(0.40, 0.6), to: Vec2(0.476, 0.6), seconds: 0.2, startingAt: 0) == [.left])
    }

    @Test func shortDropoutsDoNotBreakASwipe() {
        var detector = SwipeDetector()
        // A fast swipe blurs the hand out of tracking for a few frames in the middle of the stroke.
        let fired = sweep(&detector, from: Vec2(0.3, 0.6), to: Vec2(0.6, 0.6), seconds: 0.3, startingAt: 0, dropFrames: [2, 3, 4, 5])
        #expect(fired == [.left])
    }

    @Test func aStrokeThatStallsMidFlightIsStillOneStroke() {
        var detector = SwipeDetector()
        // Recorded strokes pause for up to 0.24 s partway; split in two, both halves are too small to qualify.
        var fired = sweep(&detector, from: Vec2(0.30, 0.6), to: Vec2(0.38, 0.6), seconds: 0.1, startingAt: 0, tail: 0.2)
        fired += sweep(&detector, from: Vec2(0.38, 0.6), to: Vec2(0.46, 0.6), seconds: 0.1, startingAt: 0.33)
        #expect(fired == [.left])
    }

    @Test func startHeightIsOffByDefaultButAvailable() {
        var detector = SwipeDetector()
        #expect(sweep(&detector, from: Vec2(0.3, 0.1), to: Vec2(0.6, 0.1), seconds: 0.3, startingAt: 0) == [.left])
        var settings = SwipeDetector.Settings()
        settings.minStartHeight = 0.2
        var gated = SwipeDetector(settings: settings)
        #expect(sweep(&gated, from: Vec2(0.3, 0.1), to: Vec2(0.6, 0.1), seconds: 0.3, startingAt: 0).isEmpty)
    }

    @Test func swipeMayDipBelowTheStartHeight() {
        var settings = SwipeDetector.Settings()
        settings.minStartHeight = 0.2
        var detector = SwipeDetector(settings: settings)
        #expect(sweep(&detector, from: Vec2(0.3, 0.26), to: Vec2(0.45, 0.17), seconds: 0.25, startingAt: 0) == [.left])
    }

    @Test func aControlPinchNeverSwipes() {
        var detector = SwipeDetector()
        // Thumb and index together on a hand that isn't flat: a volume or brightness drag, whatever it travels.
        #expect(sweep(&detector, from: Vec2(0.3, 0.6), to: Vec2(0.6, 0.6), seconds: 0.3, startingAt: 0,
                      flat: { _ in false }, pinching: true).isEmpty)
    }

    @Test func aFlatHandThatReadsAsAPinchStillSwipes() {
        var detector = SwipeDetector()
        // A swiping hand tucks its thumb against an outstretched index and PinchTracker holds on for four frames
        // after that, so recorded strokes were pinched for most of their length and were being thrown away.
        #expect(sweep(&detector, from: Vec2(0.3, 0.6), to: Vec2(0.6, 0.6), seconds: 0.3, startingAt: 0,
                      pinching: true) == [.left])
    }

    @Test func invertSwapsDirections() {
        var settings = SwipeDetector.Settings()
        settings.invert = true
        var detector = SwipeDetector(settings: settings)
        #expect(sweep(&detector, from: Vec2(0.3, 0.6), to: Vec2(0.6, 0.6), seconds: 0.3, startingAt: 0) == [.right])
    }
}
