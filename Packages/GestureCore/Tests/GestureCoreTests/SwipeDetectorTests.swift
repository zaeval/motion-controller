import Foundation
import Testing
@testable import GestureCore

struct SwipeDetectorTests {
    private static let frame = 1.0 / 30

    /// Feeds frames from `t0` for `seconds`, the anchor moving linearly from `start` to `end`, and returns every swipe.
    private func feed(
        _ detector: inout SwipeDetector,
        from start: Vec2,
        to end: Vec2? = nil,
        seconds: TimeInterval,
        at t0: TimeInterval,
        facing: Bool? = true,
        flat: Bool = true,
        fist: Bool = false,
        pinching: Bool = false,
        dropFrames: Set<Int> = []
    ) -> [SwipeDirection] {
        let target = end ?? start
        let frames = max(1, Int((seconds / Self.frame).rounded()))
        return (0..<frames).compactMap { index in
            let progress = Double(index + 1) / Double(frames)
            let sample = dropFrames.contains(index) ? nil : SwipeDetector.Sample(
                anchor: start + (target - start) * progress, flatHand: flat, pinching: pinching, fist: fist,
                palmFacesCamera: facing, imageAspect: 1
            )
            return detector.update(sample, at: t0 + Double(index) * Self.frame)
        }
    }

    @Test func aPalmHeldStillThenSweptSwitches() {
        var toLeft = SwipeDetector()
        #expect(feed(&toLeft, from: Vec2(0.5, 0.6), seconds: 0.4, at: 0).isEmpty)
        #expect(toLeft.isArmed)
        // Image x grows toward the user's left.
        #expect(feed(&toLeft, from: Vec2(0.5, 0.6), to: Vec2(0.7, 0.6), seconds: 0.25, at: 0.4) == [.left])
        #expect(!toLeft.isArmed)

        var toRight = SwipeDetector()
        _ = feed(&toRight, from: Vec2(0.5, 0.6), seconds: 0.4, at: 0)
        #expect(feed(&toRight, from: Vec2(0.5, 0.6), to: Vec2(0.28, 0.55), seconds: 0.25, at: 0.4) == [.right])
    }

    @Test func aHandThatNeverStoodStillNeverSwitches() {
        var detector = SwipeDetector()
        #expect(feed(&detector, from: Vec2(0.3, 0.6), to: Vec2(0.7, 0.6), seconds: 0.3, at: 0).isEmpty)
        // Too short a pause: shorter than `armSeconds`, which is 0.15 s since the user asked for the wait to go.
        _ = feed(&detector, from: Vec2(0.7, 0.6), seconds: 0.08, at: 2)
        #expect(!detector.isArmed)
        #expect(feed(&detector, from: Vec2(0.7, 0.6), to: Vec2(0.4, 0.6), seconds: 0.3, at: 2.2).isEmpty)
    }

    @Test func theBackOfTheHandAFistOrAPinchDoesNotArm() {
        for (facing, flat) in [(false, true), (nil, true), (true, false)] as [(Bool?, Bool)] {
            var detector = SwipeDetector()
            _ = feed(&detector, from: Vec2(0.5, 0.6), seconds: 0.5, at: 0, facing: facing, flat: flat)
            #expect(!detector.isArmed)
            #expect(feed(&detector, from: Vec2(0.5, 0.6), to: Vec2(0.75, 0.6), seconds: 0.25, at: 0.5).isEmpty)
        }
        // Held right, then folded into a fist and pulled away: the parking gesture.
        var parking = SwipeDetector()
        _ = feed(&parking, from: Vec2(0.5, 0.6), seconds: 0.5, at: 0)
        #expect(feed(&parking, from: Vec2(0.5, 0.6), to: Vec2(0.75, 0.6), seconds: 0.25, at: 0.5, flat: false, fist: true).isEmpty)
        // Held right, then pinched into a volume or brightness drag.
        var dragging = SwipeDetector()
        _ = feed(&dragging, from: Vec2(0.5, 0.6), seconds: 0.5, at: 0)
        #expect(feed(&dragging, from: Vec2(0.5, 0.6), to: Vec2(0.75, 0.6), seconds: 0.25, at: 0.5, flat: false, pinching: true).isEmpty)
    }

    @Test func aWindUpTheOtherWayDoesNotDecideTheDirection() {
        var detector = SwipeDetector()
        _ = feed(&detector, from: Vec2(0.5, 0.6), seconds: 0.4, at: 0)
        var fired = feed(&detector, from: Vec2(0.5, 0.6), to: Vec2(0.41, 0.6), seconds: 0.15, at: 0.4)
        fired += feed(&detector, from: Vec2(0.41, 0.6), to: Vec2(0.72, 0.6), seconds: 0.25, at: 0.55)
        #expect(fired == [.left])
    }

    @Test func theWayBackIsNotASwipeEvenAfterAPauseAtTheEnd() {
        var detector = SwipeDetector()
        _ = feed(&detector, from: Vec2(0.5, 0.6), seconds: 0.4, at: 0)
        var fired = feed(&detector, from: Vec2(0.5, 0.6), to: Vec2(0.72, 0.6), seconds: 0.2, at: 0.4)
        fired += feed(&detector, from: Vec2(0.72, 0.6), seconds: 0.35, at: 0.6)
        fired += feed(&detector, from: Vec2(0.72, 0.6), to: Vec2(0.5, 0.6), seconds: 0.2, at: 0.95)
        #expect(fired == [.left])
    }

    @Test func swipingAgainTakesAnotherHold() {
        var detector = SwipeDetector()
        _ = feed(&detector, from: Vec2(0.5, 0.6), seconds: 0.4, at: 0)
        var fired = feed(&detector, from: Vec2(0.5, 0.6), to: Vec2(0.72, 0.6), seconds: 0.2, at: 0.4)
        // Straight back and straight over again, with no hold in between.
        fired += feed(&detector, from: Vec2(0.72, 0.6), to: Vec2(0.5, 0.6), seconds: 0.3, at: 0.6)
        fired += feed(&detector, from: Vec2(0.5, 0.6), to: Vec2(0.72, 0.6), seconds: 0.2, at: 0.9)
        #expect(fired == [.left])
        // Back, held, and over again.
        fired += feed(&detector, from: Vec2(0.72, 0.6), to: Vec2(0.5, 0.6), seconds: 0.3, at: 1.1)
        fired += feed(&detector, from: Vec2(0.5, 0.6), seconds: 0.4, at: 1.4)
        fired += feed(&detector, from: Vec2(0.5, 0.6), to: Vec2(0.72, 0.6), seconds: 0.2, at: 1.8)
        #expect(fired == [.left, .left])
    }

    @Test func aSlowDriftOrAHandComingDownDoesNotSwitch() {
        var drifting = SwipeDetector()
        _ = feed(&drifting, from: Vec2(0.5, 0.6), seconds: 0.4, at: 0)
        #expect(feed(&drifting, from: Vec2(0.5, 0.6), to: Vec2(0.7, 0.6), seconds: 1.5, at: 0.4).isEmpty)

        var lowering = SwipeDetector()
        _ = feed(&lowering, from: Vec2(0.5, 0.6), seconds: 0.4, at: 0)
        var fired = feed(&lowering, from: Vec2(0.5, 0.6), to: Vec2(0.52, 0.35), seconds: 0.25, at: 0.4)
        fired += feed(&lowering, from: Vec2(0.52, 0.35), to: Vec2(0.75, 0.35), seconds: 0.25, at: 0.65)
        #expect(fired.isEmpty)
    }

    @Test func aStrokeThatBlursOutOfTrackingStillSwitches() {
        var gap = SwipeDetector()
        _ = feed(&gap, from: Vec2(0.5, 0.6), seconds: 0.4, at: 0)
        #expect(feed(&gap, from: Vec2(0.5, 0.6), to: Vec2(0.75, 0.6), seconds: 0.3, at: 0.4, dropFrames: [2, 3, 4, 5]) == [.left])

        var gone = SwipeDetector()
        _ = feed(&gone, from: Vec2(0.5, 0.6), seconds: 0.4, at: 0)
        var fired = feed(&gone, from: Vec2(0.5, 0.6), to: Vec2(0.59, 0.6), seconds: 0.1, at: 0.4)
        fired += (0..<20).compactMap { gone.update(nil, at: 0.5 + Double($0) * Self.frame) }
        #expect(fired == [.left])
    }

    @Test func invertSwapsDirections() {
        var settings = SwipeDetector.Settings()
        settings.invert = true
        var detector = SwipeDetector(settings: settings)
        _ = feed(&detector, from: Vec2(0.5, 0.6), seconds: 0.4, at: 0)
        #expect(feed(&detector, from: Vec2(0.5, 0.6), to: Vec2(0.7, 0.6), seconds: 0.25, at: 0.4) == [.right])
    }
}
