import Foundation
import Testing
@testable import GestureCore

struct ActionEvaluatorTests {
    private static let frame = 1.0 / 30

    private func reading(
        _ pose: StaticPose? = nil, still: Bool = true, pump: Bool = false,
        steps: [PinchAxisControl.Step] = [], zoomStep: Int = 0,
        at time: TimeInterval
    ) -> GestureReading {
        GestureReading(
            timestamp: time, chirality: .right, pose: pose, isPinching: pose == .pinch, pinchAxis: nil,
            pinchTotals: [:], palmSpeed: still ? 0 : 2, isSweeping: !still, isStill: still, inActiveRegion: true,
            openness: nil, palmFacesCamera: true, extendedFingers: [], steps: steps, zoomStep: zoomStep,
            pointer: Vec2(0.5, 0.5), handScale: 0.15, imageAspect: 16.0 / 9, isFist: pose == .fist, tap: nil,
            isTapDipping: false, idleGesture: false, palmPump: pump, isIndexBent: false, indexReachAlongPalm: nil,
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

    @Test func pumpingThePalmPlaysOrPauses() {
        var evaluator = ActionEvaluator()
        // 🖐 pushed out and back twice; `PalmPumpDetector` is what decides that, and this is what it means.
        #expect(evaluator.update(reading(.openPalm, pump: true, at: 0), at: 0) == [.media(.playPause)])
        // Holding the palm out does nothing here any more: that opens desktop mode, which is `ModeController`'s.
        #expect(feed(&evaluator, from: 0.1, seconds: 3.0) { reading(.openPalm, at: $0) }.isEmpty)
    }

    @Test func noHeldPoseFiresAnythingByItself() {
        var evaluator = ActionEvaluator()
        // Play/pause is a pump and desktop switching is its own mode, so no static pose is mapped. The hold
        // machinery stays for the mapping editor (plan M5); this is what stops something being mapped by accident.
        for pose in StaticPose.allCases {
            var fresh = ActionEvaluator()
            #expect(feed(&fresh, from: 0, seconds: 3.0) { reading(pose, at: $0) }.isEmpty, "\(pose)")
            #expect(feed(&fresh, from: 3.0, seconds: 1.0) { _ in nil }.isEmpty, "\(pose)")
        }
        #expect(evaluator.pending(at: 0) == nil)
    }

    /// The user's own park held the palm past the old hold before folding it (logged 2026-09-14). Nothing about a
    /// park may reach the media keys; that it can't pump is `PalmPumpDetectorTests.aParkNeverPumps`.
    @Test func aParkingGestureFiresNothing() {
        var evaluator = ActionEvaluator()
        #expect(feed(&evaluator, from: 0, seconds: 1.6) { reading(.openPalm, at: $0) }.isEmpty)
        // One frame between palm and fist, as one recorded park had.
        #expect(feed(&evaluator, from: 1.6, seconds: 1.0 / 30) { reading(at: $0) }.isEmpty)
        #expect(feed(&evaluator, from: 1.6 + 1.0 / 30, seconds: 0.6) { reading(.fist, at: $0) }.isEmpty)
        #expect(feed(&evaluator, from: 2.3, seconds: 1.0) { _ in nil }.isEmpty)
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
        // Swiping rotates the hand and pulls it back in: that in-and-out is not a pump.
        #expect(feed(&evaluator, from: 0.03, seconds: 1.0) { reading(.openPalm, pump: true, at: $0) }.isEmpty)
        // Well past the swipe, a pump is meant again.
        #expect(evaluator.update(reading(.openPalm, pump: true, at: 1.2), at: 1.2) == [.media(.playPause)])
    }

    @Test func swipingGoesWhereTheHandPoints() {
        var evaluator = ActionEvaluator()
        // Sweeping toward the user's right goes to the desktop on the right: their call, 2026-09-13 and again
        // 2026-09-14 when a build shipped the trackpad-like opposite.
        #expect(evaluator.update(reading(.openPalm, still: false, at: 0), swipe: .right, at: 0) == [.desktop(.next)])
        #expect(evaluator.update(reading(.openPalm, still: false, at: 1), swipe: .left, at: 1) == [.desktop(.previous)])
        evaluator.settings.swipesSwitchDesktops = false
        #expect(evaluator.update(reading(.openPalm, still: false, at: 2), swipe: .right, at: 2).isEmpty)
    }

    @Test func aLostHandFiresNothing() {
        var evaluator = ActionEvaluator()
        _ = feed(&evaluator, from: 0, seconds: 1.0) { reading(.openPalm, at: $0) }
        #expect(feed(&evaluator, from: 1.0, seconds: 0.2) { _ in nil }.isEmpty)
        #expect(feed(&evaluator, from: 1.2, seconds: 1.0) { reading(.openPalm, at: $0) }.isEmpty)
    }
}
