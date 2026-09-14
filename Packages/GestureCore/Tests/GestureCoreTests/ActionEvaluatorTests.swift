import Foundation
import Testing
@testable import GestureCore

struct ActionEvaluatorTests {
    private static let frame = 1.0 / 30

    private func reading(
        _ pose: StaticPose? = nil, still: Bool = true, steps: [PinchAxisControl.Step] = [], zoomStep: Int = 0,
        at time: TimeInterval
    ) -> GestureReading {
        GestureReading(
            timestamp: time, chirality: .right, pose: pose, isPinching: pose == .pinch, pinchAxis: nil,
            pinchTotals: [:], palmSpeed: still ? 0 : 2, isSweeping: !still, isStill: still, inActiveRegion: true,
            openness: nil, palmFacesCamera: true, extendedFingers: [], steps: steps, zoomStep: zoomStep,
            pointer: Vec2(0.5, 0.5), handScale: 0.15, imageAspect: 16.0 / 9, isFist: pose == .fist, tap: nil,
            isTapDipping: false, idleGesture: false, isIndexBent: false, indexReachAlongPalm: nil,
            straightIndexReach: nil
        )
    }

    /// Feeds `seconds` of frames from `start` and returns every action in order.
    private func feed(
        _ evaluator: inout ActionEvaluator, from start: TimeInterval, seconds: TimeInterval,
        _ make: (TimeInterval) -> GestureReading?
    ) -> [GestureAction] {
        (0..<Int((seconds / Self.frame).rounded())).flatMap { index -> [GestureAction] in
            let time = start + Double(index) * Self.frame
            return evaluator.update(make(time), at: time)
        }
    }

    @Test func aHeldOpenPalmPlaysAndPausesOnceItComesDown() {
        var evaluator = ActionEvaluator()
        // A parking gesture shows the palm for 0.6–0.9 s: no hold yet.
        #expect(feed(&evaluator, from: 0, seconds: 0.9) { reading(.openPalm, at: $0) }.isEmpty)
        #expect((evaluator.pending(at: 0.9)?.progress ?? 0) < 1)
        // Held past the hold, it waits however long the palm stays up.
        #expect(feed(&evaluator, from: 0.9, seconds: 3.0) { reading(.openPalm, at: $0) }.isEmpty)
        #expect(evaluator.pending(at: 3.9)?.progress == 1)
        // Down: it fires once the grace has passed without a fist, and only once.
        #expect(feed(&evaluator, from: 3.9, seconds: 0.2) { _ in nil }.isEmpty)
        #expect(feed(&evaluator, from: 4.1, seconds: 1.0) { _ in nil } == [.media(.playPause)])
        #expect(evaluator.pending(at: 5.1) == nil)
        // Another hold, let go into a different pose, fires again.
        #expect(feed(&evaluator, from: 5.1, seconds: 1.6) { reading(.openPalm, at: $0) }.isEmpty)
        #expect(feed(&evaluator, from: 6.7, seconds: 1.0) { reading(.pointIndex, at: $0) } == [.media(.playPause)])
    }

    /// The user's own park held the palm past the hold before folding it (logged 2026-09-14).
    @Test func aHeldPalmFoldedIntoAFistIsTheParkingGestureNotPlayPause() {
        var evaluator = ActionEvaluator()
        #expect(feed(&evaluator, from: 0, seconds: 1.6) { reading(.openPalm, at: $0) }.isEmpty)
        #expect(evaluator.pending(at: 1.6)?.progress == 1)
        // One frame between palm and fist, as one recorded park had.
        #expect(feed(&evaluator, from: 1.6, seconds: 1.0 / 30) { reading(at: $0) }.isEmpty)
        #expect(feed(&evaluator, from: 1.6 + 1.0 / 30, seconds: 0.6) { reading(.fist, at: $0) }.isEmpty)
        #expect(feed(&evaluator, from: 2.3, seconds: 1.0) { _ in nil }.isEmpty)
        #expect(evaluator.pending(at: 3.3) == nil)
    }

    @Test func aMovingHandNeverFinishesAHold() {
        var evaluator = ActionEvaluator()
        #expect(feed(&evaluator, from: 0, seconds: 3.0) { reading(.openPalm, still: false, at: $0) }.isEmpty)
    }

    @Test func neitherHeldThreeFingersNorTheBackOfTheHandDoAnything() {
        // ⌘Tab is gone: three fingers zoom now, and only by moving.
        var evaluator = ActionEvaluator()
        #expect(feed(&evaluator, from: 0, seconds: 3.0) { reading(.threeFingers, at: $0) }.isEmpty)
        // Mute is gone: the pinch drag covers volume, and the back of the hand kept firing on a swipe's return.
        var back = ActionEvaluator()
        #expect(feed(&back, from: 0, seconds: 3.0) { reading(.backOfHand, at: $0) }.isEmpty)
    }

    @Test func zoomStepsPressTheZoomShortcuts() {
        var evaluator = ActionEvaluator()
        #expect(evaluator.update(reading(.threeFingers, zoomStep: 1, at: 0), at: 0) == [.keyCombo(.zoomIn)])
        #expect(evaluator.update(reading(.threeFingers, zoomStep: -1, at: 0.2), at: 0.2) == [.keyCombo(.zoomOut)])
    }

    @Test func zoomingAndSwipingDoNotTriggerEachOther() {
        // The hand coming back from a swipe can read as three fingers on the move.
        var swiped = ActionEvaluator()
        #expect(swiped.update(reading(.openPalm, still: false, at: 0), swipe: .right, at: 0) == [.desktop(.next)])
        #expect(swiped.update(reading(.threeFingers, still: false, zoomStep: 1, at: 0.5), at: 0.5).isEmpty)
        // A zooming hand that drifts sideways isn't switching desktops.
        var zoomed = ActionEvaluator()
        #expect(zoomed.update(reading(.threeFingers, zoomStep: 1, at: 0), at: 0) == [.keyCombo(.zoomIn)])
        #expect(zoomed.update(reading(.threeFingers, still: false, at: 0.6), swipe: .left, at: 0.6).isEmpty)
        #expect(zoomed.update(reading(.openPalm, still: false, at: 2), swipe: .left, at: 2) == [.desktop(.previous)])
    }

    @Test func pinchTravelStepsVolumeAndBrightness() {
        var evaluator = ActionEvaluator()
        let up = evaluator.update(reading(.pinch, steps: [.init(target: .volume, delta: 1)], at: 0), at: 0)
        #expect(up == [.media(.volumeUp)])
        let down = evaluator.update(reading(.pinch, steps: [.init(target: .volume, delta: -2)], at: 0.1), at: 0.1)
        #expect(down == [.media(.volumeDown), .media(.volumeDown)])
        let brighter = evaluator.update(reading(.pinch, steps: [.init(target: .brightness, delta: 1)], at: 0.2), at: 0.2)
        #expect(brighter == [.media(.brightnessUp)])
    }

    @Test func aPoseRightAfterASwipeIsJustTheHandComingBack() {
        var evaluator = ActionEvaluator()
        #expect(evaluator.update(reading(.openPalm, still: false, at: 0), swipe: .right, at: 0) == [.desktop(.next)])
        // Swiping rotates the hand: whatever it looks like on the way back is not a command.
        #expect(feed(&evaluator, from: 0.03, seconds: 1.2) { reading(.openPalm, at: $0) }.isEmpty)
        // Held on well past the swipe, it is meant, and fires once the palm comes down.
        #expect(feed(&evaluator, from: 1.23, seconds: 1.5) { reading(.openPalm, at: $0) }.isEmpty)
        #expect(feed(&evaluator, from: 2.73, seconds: 1.0) { _ in nil } == [.media(.playPause)])
    }

    @Test func swipingSwitchesDesktopsLikeATrackpad() {
        var evaluator = ActionEvaluator()
        // Toward the user's right is the next desktop.
        #expect(evaluator.update(reading(.openPalm, still: false, at: 0), swipe: .right, at: 0) == [.desktop(.next)])
        #expect(evaluator.update(reading(.openPalm, still: false, at: 1), swipe: .left, at: 1) == [.desktop(.previous)])
        evaluator.settings.swipesSwitchDesktops = false
        #expect(evaluator.update(reading(.openPalm, still: false, at: 2), swipe: .right, at: 2).isEmpty)
    }

    @Test func aLostHandDropsAHoldInProgress() {
        var evaluator = ActionEvaluator()
        _ = feed(&evaluator, from: 0, seconds: 1.0) { reading(.openPalm, at: $0) }
        #expect(evaluator.pending(at: 1.0)?.pose == .openPalm)
        #expect(feed(&evaluator, from: 1.0, seconds: 0.2) { _ in nil }.isEmpty)
        #expect(evaluator.pending(at: 1.2) == nil)
        #expect(feed(&evaluator, from: 1.2, seconds: 1.0) { reading(.openPalm, at: $0) }.isEmpty)
    }
}
