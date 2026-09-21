import Foundation
import Testing
@testable import GestureCore

struct OwnerTrackerTests {
    private func point(_ x: Double, _ y: Double) -> JointPoint {
        JointPoint(position: Vec2(x, y), confidence: 0.9)
    }

    /// A person whose head is at `x` with a hand of their own.
    private func body(at x: Double, handAt handX: Double? = nil) -> Body {
        Body(
            joints: [.nose: point(x, 0.7), .neck: point(x, 0.6)],
            leftHand: handX.map { hand(wristAt: $0, 0.5) },
            timestamp: 0,
            imageAspect: 1
        )
    }

    private func hand(wristAt x: Double, _ y: Double) -> HandFrame {
        HandFrame(joints: [.wrist: point(x, y)], chirality: .unknown, timestamp: 0, imageAspect: 1)
    }

    private func frame(_ bodies: [Body], loose: [HandFrame] = []) -> PoseFrame {
        PoseFrame(bodies: bodies, looseHands: loose, timestamp: 0, imageAspect: 1)
    }

    @Test func aRecognizedFacePinsTheOwnerToTheNearestHead() {
        var tracker = OwnerTracker()
        let heads: [Vec2?] = [Vec2(0.25, 0.7), Vec2(0.75, 0.7)]
        #expect(tracker.sawOwner(faceCenter: Vec2(0.73, 0.72), heads: heads, at: 0) == 1)
        #expect(tracker.isFollowing(at: 0))
        // A face nowhere near anybody's head pins nothing.
        var lonely = OwnerTracker()
        #expect(lonely.sawOwner(faceCenter: Vec2(0.2, 0.2), heads: [Vec2(0.8, 0.8)], at: 0) == nil)
        #expect(!lonely.isFollowing(at: 0))
    }

    @Test func theOwnerIsFollowedAsTheyMoveAndAPasserByDoesNotStealThePin() {
        var tracker = OwnerTracker()
        _ = tracker.sawOwner(faceCenter: Vec2(0.3, 0.7), heads: [Vec2(0.3, 0.7)], at: 0)
        // They drift right over a few frames, someone else walks in on the far side.
        #expect(tracker.follow(heads: [Vec2(0.36, 0.7), Vec2(0.9, 0.72)], at: 0.1) == 0)
        #expect(tracker.follow(heads: [Vec2(0.44, 0.71), Vec2(0.8, 0.72)], at: 0.2) == 0)
        // The other person takes the first slot: the owner is followed by where they were, not by their index.
        #expect(tracker.follow(heads: [Vec2(0.7, 0.72), Vec2(0.5, 0.71)], at: 0.3) == 1)
    }

    @Test func aLeapTooFarIsNotTheOwnerAndTheePinGoesStale() {
        var tracker = OwnerTracker()
        _ = tracker.sawOwner(faceCenter: Vec2(0.3, 0.7), heads: [Vec2(0.3, 0.7)], at: 0)
        #expect(tracker.follow(heads: [Vec2(0.9, 0.7)], at: 0.1) == nil)
        #expect(tracker.isFollowing(at: 0.1))
        // Ten seconds with no face confirming them and the pin is gone.
        #expect(tracker.follow(heads: [Vec2(0.3, 0.7)], at: 11) == nil)
        #expect(!tracker.isFollowing(at: 11))
    }

    @Test func onlyTheOwnersHandsAreAllowedOnceSomebodyElseIsThere() {
        var tracker = OwnerTracker()
        let people = [body(at: 0.25, handAt: 0.2), body(at: 0.75, handAt: 0.8)]
        let scene = frame(people)
        let owner = tracker.sawOwner(faceCenter: Vec2(0.75, 0.7), heads: [Vec2(0.25, 0.7), Vec2(0.75, 0.7)], at: 0)
        #expect(owner == 1)
        let allowed = tracker.allowedHands(in: scene, owner: owner)
        #expect(allowed.count == 1)
        #expect(allowed.first?.normalizedPosition(of: .wrist) == Vec2(0.8, 0.5))
    }

    @Test func aHandWithNoBodyCountsWhenItIsTheOwnersOwn() {
        var tracker = OwnerTracker()
        let raised = hand(wristAt: 0.7, 0.55)
        let strangers = hand(wristAt: 0.1, 0.5)
        let scene = frame([body(at: 0.25), body(at: 0.75)], loose: [raised, strangers])
        let owner = tracker.sawOwner(faceCenter: Vec2(0.75, 0.7), heads: [Vec2(0.25, 0.7), Vec2(0.75, 0.7)], at: 0)
        let allowed = tracker.allowedHands(in: scene, owner: owner)
        #expect(allowed.map { $0.normalizedPosition(of: .wrist) } == [Vec2(0.7, 0.55)])
    }

    @Test func withNobodyPinnedOnePersonStillCountsAndTwoDoNot() {
        let tracker = OwnerTracker()
        let alone = frame([body(at: 0.5, handAt: 0.5)])
        #expect(tracker.allowedHands(in: alone, owner: nil).count == 1)
        let crowd = frame([body(at: 0.25, handAt: 0.2), body(at: 0.75, handAt: 0.8)])
        #expect(tracker.allowedHands(in: crowd, owner: nil).isEmpty)
        // A hand with nobody attached to it at all is still one person's.
        let handOnly = frame([], loose: [hand(wristAt: 0.5, 0.5)])
        #expect(tracker.allowedHands(in: handOnly, owner: nil).count == 1)
    }

    @Test func resettingForgetsTheOwner() {
        var tracker = OwnerTracker()
        _ = tracker.sawOwner(faceCenter: Vec2(0.3, 0.7), heads: [Vec2(0.3, 0.7)], at: 0)
        tracker.reset()
        #expect(!tracker.isFollowing(at: 0))
        #expect(tracker.follow(heads: [Vec2(0.3, 0.7)], at: 0.1) == nil)
    }
}
