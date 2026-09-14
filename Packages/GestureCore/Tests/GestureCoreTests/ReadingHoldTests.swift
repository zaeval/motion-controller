import Foundation
import Testing
@testable import GestureCore

struct ReadingHoldTests {

    private func reading(
        pose: StaticPose? = .fist, pump: Bool = false, tap: FingerTap? = nil, at time: TimeInterval
    ) -> GestureReading {
        GestureReading(
            timestamp: time, chirality: .right, pose: pose, isPinching: false, pinchAxis: nil, pinchTotals: [:],
            palmSpeed: 0, isSweeping: false, isStill: true, inActiveRegion: true, openness: nil,
            palmFacesCamera: true, extendedFingers: [], steps: [.init(target: .volume, delta: 1)], zoomStep: 1,
            pointer: Vec2(0.5, 0.5), handScale: 0.15, imageAspect: 16.0 / 9, isFist: true, tap: tap,
            isTapDipping: false, idleGesture: true, fistPump: pump, isIndexBent: false, indexReachAlongPalm: nil,
            straightIndexReach: nil
        )
    }

    /// Two readings in a row agreeing on the shape: from then on it stands in for lost frames.
    private func settle(_ hold: inout ReadingHold, pose: StaticPose? = .fist, from start: TimeInterval = 0) {
        _ = hold.update(reading(pose: pose, at: start), at: start)
        _ = hold.update(reading(pose: pose, at: start + 0.03), at: start + 0.03)
    }

    @Test func aFreshReadingPassesStraightThrough() {
        var hold = ReadingHold()
        let fresh = reading(pump: true, tap: .left, at: 0)
        let out = hold.update(fresh, at: 0)
        #expect(out?.fistPump == true)
        #expect(out?.tap == .left)
        #expect(!hold.isHolding)
    }

    /// A shape seen once and gone is a mistracked frame, not something to stand in for: held, it would be six frames
    /// of a shape nobody made, which is long enough to open a mode.
    @Test func aStrayFrameNeverStandsIn() {
        var hold = ReadingHold()
        _ = hold.update(reading(pose: .pointIndex, at: 0), at: 0)
        _ = hold.update(reading(pose: .openPalm, at: 0.03), at: 0.03)
        #expect(hold.update(nil, at: 0.06) == nil)
        #expect(!hold.isHolding)
    }

    /// A frame Vision lost the hand in: the shape stands, the events don't — or a knock would play twice and a tap
    /// would click twice.
    @Test func aLostFrameKeepsTheShapeAndDropsTheEvents() {
        var hold = ReadingHold()
        _ = hold.update(reading(at: 0), at: 0)
        _ = hold.update(reading(pump: true, tap: .left, at: 0.03), at: 0.03)
        let stood = hold.update(nil, at: 0.06)
        #expect(hold.isHolding)
        #expect(stood?.isFist == true)
        #expect(stood?.pose == .fist)
        #expect(stood?.fistPump == false)
        #expect(stood?.tap == nil)
        #expect(stood?.idleGesture == false)
        #expect(stood?.zoomStep == 0)
        #expect(stood?.steps.isEmpty == true)
    }

    @Test func aHandThatStaysGoneIsGone() {
        var hold = ReadingHold()
        settle(&hold)
        #expect(hold.update(nil, at: 0.19) != nil)
        #expect(hold.update(nil, at: 0.25) == nil)
        #expect(!hold.isHolding)
        // And it doesn't come back from the dead on the next gap.
        #expect(hold.update(nil, at: 0.26) == nil)
    }

    @Test func resetForgetsTheHand() {
        var hold = ReadingHold()
        settle(&hold)
        hold.reset()
        #expect(hold.update(nil, at: 0.05) == nil)
    }
}
