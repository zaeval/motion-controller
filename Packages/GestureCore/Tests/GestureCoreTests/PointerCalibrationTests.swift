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

    /// Holds the hand at `point` for `seconds` and returns the box if calibration finished in that time.
    private func hold(
        _ calibration: inout PointerCalibration, at point: Vec2, seconds: TimeInterval, from start: TimeInterval
    ) -> InteractionBox? {
        var box: InteractionBox?
        for index in 0...Int((seconds / Self.frame).rounded()) {
            if let finished = calibration.update(point, at: start + Double(index) * Self.frame) {
                box = finished
            }
        }
        return box
    }

    private func isClose(_ a: Vec2, _ b: Vec2, tolerance: Double = 1e-9) -> Bool {
        a.distance(to: b) <= tolerance
    }

    @Test func pointingAtFourCornersBuildsTheBoxThatMapsThem() {
        var calibration = PointerCalibration()
        var box: InteractionBox?
        for (index, corner) in PointerCalibration.Corner.allCases.enumerated() {
            #expect(calibration.corner == corner)
            box = hold(&calibration, at: Self.corners[corner]!, seconds: 1.0, from: Double(index) * 2)
        }
        let finished = try? #require(box)
        #expect(calibration.corner == nil)
        guard let finished else { return }
        // Each corner the user pointed at now maps to that corner of the screen.
        #expect(isClose(finished.screenPoint(forCamera: Self.corners[.topLeft]!), Vec2(0, 0)))
        #expect(isClose(finished.screenPoint(forCamera: Self.corners[.topRight]!), Vec2(1, 0)))
        #expect(isClose(finished.screenPoint(forCamera: Self.corners[.bottomRight]!), Vec2(1, 1)))
        #expect(isClose(finished.screenPoint(forCamera: Self.corners[.bottomLeft]!), Vec2(0, 1)))
    }

    @Test func aWanderingHandNeverFinishesACorner() {
        var calibration = PointerCalibration()
        for index in 0..<120 {
            let drifting = Vec2(0.5 + 0.01 * Double(index), 0.5)
            #expect(calibration.update(drifting, at: Double(index) * Self.frame) == nil)
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
        #expect(calibration.update(nil, at: 1.0) == nil)
        #expect(calibration.progress == 0)
        // Back after a gap: the hold starts from scratch, so half a second more isn't enough.
        #expect(hold(&calibration, at: Vec2(0.7, 0.7), seconds: 0.5, from: 2.0) == nil)
        #expect(calibration.capturedCount == 0)
    }

    @Test func fourCornersInTheSamePlaceStillLeaveRoomToMove() {
        var calibration = PointerCalibration()
        var box: InteractionBox?
        for (index, corner) in PointerCalibration.Corner.allCases.enumerated() {
            box = hold(&calibration, at: Vec2(0.5, 0.5), seconds: 1.0, from: Double(index) * 2)
            _ = corner
        }
        let finished = try? #require(box)
        guard let finished else { return }
        #expect(abs((1 - finished.left - finished.right) - 0.15) < 1e-9)
        #expect(abs((1 - finished.top - finished.bottom) - 0.15) < 1e-9)
    }
}
