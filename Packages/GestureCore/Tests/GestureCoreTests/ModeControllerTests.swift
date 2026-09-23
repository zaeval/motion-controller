import Foundation
import Testing
@testable import GestureCore

struct ModeControllerTests {
    private static let frame = 1.0 / 30

    private func reading(
        _ pose: StaticPose? = nil, fist: Bool = false, tap: FingerTap? = nil, idleGesture: Bool = false,
        at time: TimeInterval
    ) -> GestureReading {
        GestureReading(
            timestamp: time, chirality: .right, pose: fist ? .fist : pose, isPinching: pose == .pinch, pinchAxis: nil,
            pinchTotals: [:], palmSpeed: 0, isSweeping: false, isStill: true, inActiveRegion: true, openness: nil,
            palmFacesCamera: true, extendedFingers: [], steps: [], zoomStep: 0, pointer: Vec2(0.5, 0.6), handScale: 0.15,
            imageAspect: 16.0 / 9, isFist: fist, tap: tap, isTapDipping: false, idleGesture: idleGesture, fistPump: false,
            isIndexBent: false, indexReachAlongPalm: nil, straightIndexReach: nil
        )
    }

    /// Feeds `seconds` of frames from `start`; returns every mode change in order.
    private func feed(
        _ controller: inout ModeController, from start: TimeInterval, seconds: TimeInterval, present: Bool = true,
        otherFist: Bool = false, holdingButton: Bool = false, _ make: (TimeInterval) -> GestureReading?
    ) -> [InteractionMode] {
        (0..<Int((seconds / Self.frame).rounded())).compactMap { index in
            let time = start + Double(index) * Self.frame
            return controller.update(
                make(time), otherHandFist: otherFist, personPresent: present, holdingButton: holdingButton, at: time
            )
        }
    }

    /// Both fists up from `start` for `seconds`.
    private func twoFists(_ controller: inout ModeController, from start: TimeInterval, seconds: TimeInterval) -> [InteractionMode] {
        feed(&controller, from: start, seconds: seconds, otherFist: true) { reading(fist: true, at: $0) }
    }

    @Test func twoIndexTapsEnterPointerModeFromGestureModeOrIdle() {
        for start in [InteractionMode.normal, .idle] {
            var controller = ModeController(mode: start)
            #expect(controller.update(reading(.pointIndex, tap: .left, at: 0), personPresent: true, at: 0) == nil)
            #expect(controller.awaitingSecondTap)
            #expect(controller.update(reading(.pointIndex, at: 0.2), personPresent: true, at: 0.2) == nil)
            #expect(controller.update(reading(.pointIndex, tap: .left, at: 0.4), personPresent: true, at: 0.4) == .pointer)
        }
    }

    @Test func oneTapTapsTooFarApartRightTapsOrTapsInPointerModeDoNotSwitch() {
        var controller = ModeController()
        #expect(controller.update(reading(.pointIndex, tap: .left, at: 0), personPresent: true, at: 0) == nil)
        #expect(controller.update(reading(.pointIndex, tap: .left, at: 1), personPresent: true, at: 1) == nil)
        #expect(controller.update(reading(.victory, tap: .right, at: 3), personPresent: true, at: 3) == nil)
        #expect(controller.update(reading(.victory, tap: .right, at: 3.3), personPresent: true, at: 3.3) == nil)
        #expect(controller.mode == .normal)

        var pointer = ModeController(mode: .pointer)
        #expect(pointer.update(reading(.pointIndex, tap: .left, at: 0), personPresent: true, at: 0) == nil)
        #expect(pointer.update(reading(.pointIndex, tap: .left, at: 0.3), personPresent: true, at: 0.3) == nil)
    }

    /// The user's call (2026-09-21): both fists held up for two seconds, where the pulled-back fist used to toggle.
    @Test func twoFistsHeldForTwoSecondsComeBackToGestureMode() {
        for start in [InteractionMode.idle, .pointer, .desktop] {
            var controller = ModeController(mode: start)
            #expect(twoFists(&controller, from: 0, seconds: 1.9).isEmpty, "\(start)")
            #expect(controller.transitionProgress(at: 1.9) > 0.9, "\(start)")
            #expect(twoFists(&controller, from: 1.9, seconds: 0.3) == [.normal], "\(start)")
            #expect(controller.lastChangeReason == .fist)
        }
        // Already there: nothing to fill up.
        var normal = ModeController(mode: .normal)
        #expect(twoFists(&normal, from: 0, seconds: 3).isEmpty)
        #expect(normal.transitionProgress(at: 3) == 0)
    }

    @Test func oneFistHeldChangesNothing() {
        for start in [InteractionMode.pointer, .idle, .desktop] {
            var controller = ModeController(mode: start)
            #expect(feed(&controller, from: 0, seconds: 3) { reading(fist: true, at: $0) }.isEmpty)
            #expect(controller.mode == start)
        }
    }

    @Test func theTwoFistsRideOutADroppedFrameButStartOverAfterALongerGap() {
        var controller = ModeController(mode: .idle)
        _ = twoFists(&controller, from: 0, seconds: 1.0)
        // The other hand drops out for a fifth of a second: the hold carries on.
        _ = feed(&controller, from: 1.0, seconds: 0.2) { reading(fist: true, at: $0) }
        #expect(twoFists(&controller, from: 1.2, seconds: 0.9) == [.normal])

        var opened = ModeController(mode: .idle)
        _ = twoFists(&opened, from: 0, seconds: 1.5)
        // Both hands open for half a second: it starts over.
        _ = feed(&opened, from: 1.5, seconds: 0.5) { reading(.openPalm, at: $0) }
        #expect(opened.transitionProgress(at: 2.0) == 0)
        #expect(twoFists(&opened, from: 2.0, seconds: 1.5).isEmpty)
        #expect(twoFists(&opened, from: 3.5, seconds: 0.6) == [.normal])
    }

    @Test func aFistPulledBackParksFromEveryModeButIdle() {
        for start in [InteractionMode.normal, .pointer, .desktop] {
            var controller = ModeController(mode: start)
            #expect(controller.update(reading(fist: true, idleGesture: true, at: 0), personPresent: true, at: 0) == .idle)
            #expect(controller.lastChangeReason == .idleGesture)
        }
        var idle = ModeController(mode: .idle)
        #expect(idle.update(reading(fist: true, idleGesture: true, at: 0), personPresent: true, at: 0) == nil)
    }

    @Test func theFistsThatResumedHaveToOpenBeforeTheyCanPark() {
        var controller = ModeController(mode: .idle)
        #expect(twoFists(&controller, from: 0, seconds: 2.1) == [.normal])
        // Lowered, still closed, and read as pulled back on the way down: not a park.
        #expect(controller.update(reading(fist: true, idleGesture: true, at: 2.2), personPresent: true, at: 2.2) == nil)
        _ = feed(&controller, from: 2.3, seconds: 0.2) { reading(at: $0) }
        #expect(controller.update(reading(fist: true, idleGesture: true, at: 2.6), personPresent: true, at: 2.6) == .idle)
    }

    @Test func aPullWhileTheOtherHandIsAFistIsNotAPark() {
        var controller = ModeController(mode: .pointer)
        let pulled = controller.update(
            reading(fist: true, idleGesture: true, at: 0), otherHandFist: true, personPresent: true, at: 0
        )
        #expect(pulled == nil)
        #expect(controller.mode == .pointer)
    }

    @Test func theOtherHandsPressDoesNotHoldTheCursorBack() {
        // The other hand's fist pressed on its way up; the change lets go of it.
        var controller = ModeController(mode: .pointer)
        let changes = feed(&controller, from: 0, seconds: 2.2, otherFist: true, holdingButton: true) {
            reading(fist: true, at: $0)
        }
        #expect(changes == [.normal])
    }

    @Test func aFistNeverLeavesPointerModeWhileAPinchHoldsTheButton() {
        var controller = ModeController(mode: .pointer)
        let pulled = controller.update(
            reading(fist: true, idleGesture: true, at: 0), personPresent: true, holdingButton: true, at: 0
        )
        #expect(pulled == nil)
        #expect(controller.mode == .pointer)
    }

    @Test func nobodyInFrontParksRecognition() {
        var controller = ModeController()
        // Not an open palm: holding one out is how desktop mode is asked for.
        #expect(feed(&controller, from: 0, seconds: 1.0) { reading(.pointIndex, at: $0) }.isEmpty)
        #expect(feed(&controller, from: 1.0, seconds: 4.5, present: false) { _ in nil }.isEmpty)
        #expect(feed(&controller, from: 5.5, seconds: 1.0, present: false) { _ in nil } == [.idle])
    }

    @Test func pointerModeRidesOutALostFaceButParksOnceTheHandIsGoneToo() {
        var controller = ModeController(mode: .pointer)
        // The raised hand hides the face from the camera; the hand itself is proof enough.
        #expect(feed(&controller, from: 0, seconds: 3.0, present: false) { reading(.pointIndex, at: $0) }.isEmpty)
        #expect(controller.mode == .pointer)
        // Hand gone as well: gesture mode, and parked from there.
        #expect(feed(&controller, from: 3.0, seconds: 4.0, present: false) { _ in nil } == [.normal, .idle])
    }

    @Test func losingTheHandInPointerModeFallsBackToGestureMode() {
        var controller = ModeController(mode: .pointer)
        _ = feed(&controller, from: 0, seconds: 0.2) { reading(.pointIndex, at: $0) }
        #expect(feed(&controller, from: 0.2, seconds: 2.5) { _ in nil }.isEmpty)
        #expect(feed(&controller, from: 2.7, seconds: 1.0) { _ in nil } == [.normal])
    }

    @Test func everyChangeRecordsWhatCausedIt() {
        var controller = ModeController()
        _ = controller.update(reading(.pointIndex, tap: .left, at: 0), personPresent: true, at: 0)
        #expect(controller.update(reading(.pointIndex, tap: .left, at: 0.3), personPresent: true, at: 0.3) == .pointer)
        #expect(controller.lastChangeReason == .doubleTap)
        #expect(twoFists(&controller, from: 0.4, seconds: 2.2) == [.normal])
        #expect(controller.lastChangeReason == .fist)

        controller.set(.pointer)
        #expect(controller.lastChangeReason == .menu)
        _ = feed(&controller, from: 2.7, seconds: 0.2) { reading(.pointIndex, at: $0) }
        #expect(feed(&controller, from: 2.9, seconds: 3.5) { _ in nil } == [.normal])
        #expect(controller.lastChangeReason == .handLost)

        #expect(controller.update(reading(fist: true, idleGesture: true, at: 6.5), personPresent: true, at: 6.5) == .idle)
        #expect(controller.lastChangeReason == .idleGesture)
        controller.set(.normal)
        #expect(feed(&controller, from: 6.6, seconds: 5.5, present: false) { _ in nil } == [.idle])
        #expect(controller.lastChangeReason == .absence)
    }

    @Test func theScreenLockingParksWhateverModeItFinds() {
        for start in [InteractionMode.normal, .pointer] {
            var controller = ModeController(mode: start)
            #expect(controller.set(.idle, because: .screenLocked) == .idle)
            #expect(controller.lastChangeReason == .screenLocked)
        }
    }

    @Test func switchingOnFromTheMenuWaitsForAHand() {
        var controller = ModeController()
        controller.set(.pointer)
        #expect(feed(&controller, from: 0, seconds: 5.0) { _ in nil }.isEmpty)
        #expect(controller.mode == .pointer)
    }

    @Test func aPalmOpensDesktopModeStraightAwayAndAFistLeavesIt() {
        var controller = ModeController()
        // A frame or two of palm is enough — no hold, at the user's request (2026-09-14) — but not a single frame.
        #expect(feed(&controller, from: 0, seconds: 0.06) { reading(.openPalm, at: $0) }.isEmpty)
        #expect(feed(&controller, from: 0.07, seconds: 0.3) { reading(.openPalm, at: $0) } == [.desktop])
        // Only the sweep is recognized there; another gesture's shape hands back to gesture mode, and a fist pulled
        // back parks the way it does from gesture mode.
        #expect(controller.update(reading(fist: true, idleGesture: true, at: 1.5), personPresent: true, at: 1.5) == .idle)
    }

    @Test func onlyGestureModeOffersDesktopMode() {
        // From idle the palm means nothing: idle waits for two fists, or the cursor's two taps.
        var idle = ModeController(mode: .idle)
        #expect(feed(&idle, from: 0, seconds: 1.5) { reading(.openPalm, at: $0) }.isEmpty)
        // Nor from the cursor, where an open hand happens between taps.
        var pointer = ModeController(mode: .pointer)
        #expect(feed(&pointer, from: 0, seconds: 1.5) { reading(.openPalm, at: $0) }.isEmpty)
    }

    @Test func desktopModeParksWhenNobodyIsThereButRidesOutALostHand() {
        var controller = ModeController()
        _ = feed(&controller, from: 0, seconds: 0.9) { reading(.openPalm, at: $0) }
        #expect(controller.mode == .desktop)
        // A hand that drops between two sweeps leaves the mode alone — there is no cursor to strand.
        #expect(feed(&controller, from: 1.0, seconds: 4.0) { _ in nil }.isEmpty)
        #expect(controller.mode == .desktop)
        // Nobody in front of the camera parks it, the same as gesture mode: five seconds from the last one seen.
        #expect(feed(&controller, from: 5.1, seconds: 5.5, present: false) { _ in nil } == [.idle])
    }

    @Test func theDoubleTapStillReachesTheCursorFromDesktopMode() {
        var controller = ModeController()
        _ = feed(&controller, from: 0, seconds: 0.9) { reading(.openPalm, at: $0) }
        #expect(controller.mode == .desktop)
        #expect(controller.update(reading(tap: .left, at: 1.0), personPresent: true, at: 1.0) == nil)
        #expect(controller.update(reading(tap: .left, at: 1.2), personPresent: true, at: 1.2) == .pointer)
    }
}
