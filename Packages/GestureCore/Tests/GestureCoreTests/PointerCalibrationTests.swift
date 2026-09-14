import Foundation
import Testing
@testable import GestureCore

struct PointerCalibrationTests {
    private static let frame = 1.0 / 30
    /// Where the hand sits when pointing at each screen corner: image x grows toward the user's left, y upward.
    private static let corners: [PointerCalibration.Corner: Vec2] = [
        .topLeft: Vec2(0.75, 0.75), .topRight: Vec2(0.25, 0.75),
        .bottomRight: Vec2(0.25, 0.35), .bottomLeft: Vec2(0.75, 0.35),
    ]

    /// Holds the hand at `point` for `seconds`. Returns true if a capture landed in that time.
    private func hold(
        _ calibration: inout PointerCalibration, at point: Vec2, seconds: TimeInterval, from start: TimeInterval
    ) -> Bool {
        var captured = false
        for index in 0...Int((seconds / Self.frame).rounded()) {
            if calibration.update(point, at: start + Double(index) * Self.frame) {
                captured = true
            }
        }
        return captured
    }

    /// Points at every corner of every round, pressing the button after each, and returns the finished box.
    /// `offset` shifts the hand per round, to check what averaging does with it.
    private func runEveryCorner(
        _ calibration: inout PointerCalibration, offset: (Int) -> Vec2 = { _ in Vec2(0, 0) }
    ) -> InteractionBox? {
        var box: InteractionBox?
        var start = 0.0
        for round in 1...PointerCalibration.rounds {
            let shift = offset(round)
            for corner in PointerCalibration.Corner.allCases {
                #expect(calibration.corner == corner)
                #expect(calibration.round == round)
                let point = Vec2(Self.corners[corner]!.x + shift.x, Self.corners[corner]!.y + shift.y)
                #expect(hold(&calibration, at: point, seconds: 1.0, from: start))
                #expect(calibration.awaitingConfirmation)
                if let finished = calibration.confirm() {
                    box = finished
                }
                start += 2
            }
        }
        return box
    }

    private func isClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-9) -> Bool {
        a.distance(to: b) <= tolerance
    }

    @Test func pointingAtFourCornersTwiceBuildsTheBoxThatMapsThem() {
        var calibration = PointerCalibration()
        let box = runEveryCorner(&calibration)
        let finished = try? #require(box)
        #expect(calibration.corner == nil)
        #expect(calibration.capturedCount == PointerCalibration.totalCaptures)
        guard let finished else { return }
        // Each corner the user pointed at now maps to that corner of the screen.
        #expect(isClose(finished.screenPoint(forCamera: Self.corners[.topLeft]!), Vec2(0, 0)))
        #expect(isClose(finished.screenPoint(forCamera: Self.corners[.topRight]!), Vec2(1, 0)))
        #expect(isClose(finished.screenPoint(forCamera: Self.corners[.bottomRight]!), Vec2(1, 1)))
        #expect(isClose(finished.screenPoint(forCamera: Self.corners[.bottomLeft]!), Vec2(0, 1)))
    }

    /// The point of asking twice: the box lands between the two attempts, not on whichever came last.
    @Test func theTwoRoundsAreAveraged() {
        var calibration = PointerCalibration()
        let box = runEveryCorner(&calibration) { round in round == 1 ? Vec2(-0.04, 0) : Vec2(0.04, 0) }
        let finished = try? #require(box)
        guard let finished else { return }
        #expect(isClose(finished.screenPoint(forCamera: Self.corners[.topLeft]!), Vec2(0, 0)))
        #expect(isClose(finished.screenPoint(forCamera: Self.corners[.bottomRight]!), Vec2(1, 1)))
    }

    /// Nothing is measured until the button is pressed, so the hand on its way to the next corner is safe.
    @Test func aCaptureWaitsForTheButtonBeforeTheNextCorner() {
        var calibration = PointerCalibration()
        #expect(hold(&calibration, at: Self.corners[.topLeft]!, seconds: 1.0, from: 0))
        #expect(calibration.awaitingConfirmation)
        #expect(calibration.corner == .topLeft)
        // Holding somewhere else entirely — the next corner, say — captures nothing while the button is up.
        #expect(hold(&calibration, at: Self.corners[.topRight]!, seconds: 2.0, from: 2) == false)
        #expect(calibration.capturedCount == 1)
        #expect(calibration.confirm() == nil)
        #expect(calibration.corner == .topRight)
        #expect(!calibration.awaitingConfirmation)
    }

    @Test func redoingACornerThrowsTheCaptureAway() {
        var calibration = PointerCalibration()
        #expect(hold(&calibration, at: Vec2(0.9, 0.9), seconds: 1.0, from: 0))
        calibration.redo()
        #expect(calibration.capturedCount == 0)
        #expect(calibration.corner == .topLeft)
        #expect(calibration.round == 1)
        // And the corner can be pointed at again.
        #expect(hold(&calibration, at: Self.corners[.topLeft]!, seconds: 1.0, from: 3))
        #expect(calibration.captures(of: .topLeft) == 1)
    }

    @Test func theSecondRoundAsksForEveryCornerAgain() {
        var calibration = PointerCalibration()
        var start = 0.0
        for corner in PointerCalibration.Corner.allCases {
            #expect(hold(&calibration, at: Self.corners[corner]!, seconds: 1.0, from: start))
            #expect(calibration.confirm() == nil)
            start += 2
        }
        #expect(calibration.round == 2)
        #expect(calibration.corner == .topLeft)
        #expect(calibration.captures(of: .topLeft) == 1)
    }

    @Test func aWanderingHandNeverFinishesACorner() {
        var calibration = PointerCalibration()
        for index in 0..<120 {
            let drifting = Vec2(0.5 + 0.01 * Double(index), 0.5)
            #expect(calibration.update(drifting, at: Double(index) * Self.frame) == false)
        }
        #expect(calibration.corner == .topLeft)
        #expect(calibration.capturedCount == 0)
    }

    @Test func aLostHandStartsTheCornerOver() {
        var calibration = PointerCalibration()
        for index in 0..<15 {
            _ = calibration.update(Vec2(0.7, 0.7), at: Double(index) * Self.frame)
        }
        #expect(calibration.progress > 0)
        #expect(calibration.update(nil, at: 1.0) == false)
        #expect(calibration.progress == 0)
        // Back after a gap: the hold starts from scratch, so half a second more isn't enough.
        #expect(hold(&calibration, at: Vec2(0.7, 0.7), seconds: 0.5, from: 2.0) == false)
        #expect(calibration.capturedCount == 0)
    }

    @Test func everyCornerInTheSamePlaceStillLeavesRoomToMove() {
        var calibration = PointerCalibration()
        var box: InteractionBox?
        for index in 0..<PointerCalibration.totalCaptures {
            _ = hold(&calibration, at: Vec2(0.5, 0.5), seconds: 1.0, from: Double(index) * 2)
            if let finished = calibration.confirm() {
                box = finished
            }
        }
        let finished = try? #require(box)
        guard let finished else { return }
        #expect(abs((1 - finished.left - finished.right) - 0.15) < 1e-9)
        #expect(abs((1 - finished.top - finished.bottom) - 0.15) < 1e-9)
    }
}
