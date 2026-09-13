import Foundation
import Testing
@testable import GestureCore

struct PinchAxisControlTests {
    private static let handSize = 0.15

    /// Quarter-hand-size steps keep the arithmetic in the exact-count tests readable.
    private func quarterStepControl() -> PinchAxisControl {
        var settings = PinchAxisControl.Settings()
        settings.step = 0.25
        return PinchAxisControl(settings: settings)
    }

    /// Pinches at `points[0]` and drags through the rest; returns every step emitted.
    private func drag(_ control: inout PinchAxisControl, through points: [Vec2]) -> [PinchAxisControl.Step] {
        points.flatMap { control.update(pinching: true, anchor: $0, handSize: Self.handSize) }
    }

    private func line(from start: Vec2, to end: Vec2, frames: Int = 30) -> [Vec2] {
        (0...frames).map { start + (end - start) * (Double($0) / Double(frames)) }
    }

    @Test func verticalDragStepsVolumeUp() {
        var control = quarterStepControl()
        // Deadband 0.0225, then 0.105 of travel at 0.0375 per step → 2 steps.
        let steps = drag(&control, through: line(from: Vec2(0.5, 0.5), to: Vec2(0.5, 0.63)))
        #expect(control.axis == .vertical)
        #expect(steps == [.init(target: .volume, delta: 1), .init(target: .volume, delta: 1)])
    }

    @Test func dragTowardTheUsersRightBrightens() {
        var control = quarterStepControl()
        // The user's right is image-left in the un-mirrored frame.
        let steps = drag(&control, through: line(from: Vec2(0.5, 0.5), to: Vec2(0.37, 0.5)))
        #expect(control.axis == .horizontal)
        #expect(steps == [.init(target: .brightness, delta: 1), .init(target: .brightness, delta: 1)])
    }

    @Test func fartherDragStepsMore() {
        var short = PinchAxisControl()
        var long = PinchAxisControl()
        let shortSteps = drag(&short, through: line(from: Vec2(0.5, 0.5), to: Vec2(0.5, 0.58)))
        let longSteps = drag(&long, through: line(from: Vec2(0.5, 0.5), to: Vec2(0.5, 0.68)))
        #expect(shortSteps.count >= 2)
        #expect(longSteps.count > shortSteps.count)
        #expect(long.total(for: .volume) == longSteps.count)
    }

    @Test func diagonalDriftKeepsSteppingTheFirstAxis() {
        var control = quarterStepControl()
        // Up, then about 22° off vertical: each volume step re-bases the sideways drift before it clears the deadband.
        let path = line(from: Vec2(0.5, 0.5), to: Vec2(0.5, 0.55), frames: 10) + line(from: Vec2(0.5, 0.55), to: Vec2(0.46, 0.65), frames: 30)
        let steps = drag(&control, through: path)
        #expect(control.axis == .vertical)
        #expect(steps.count >= 2)
        #expect(steps.allSatisfy { $0.target == .volume })
    }

    @Test func movingSidewaysMidPinchSwitchesToBrightness() {
        var control = quarterStepControl()
        let up = drag(&control, through: line(from: Vec2(0.5, 0.5), to: Vec2(0.5, 0.63)))
        let sideways = drag(&control, through: line(from: Vec2(0.5, 0.63), to: Vec2(0.37, 0.63)))
        #expect(up.map(\.target) == [.volume, .volume])
        #expect(!sideways.isEmpty)
        #expect(sideways.allSatisfy { $0 == .init(target: .brightness, delta: 1) })
        #expect(control.axis == .horizontal)
        #expect(control.total(for: .volume) == 2)
        #expect(control.total(for: .brightness) == sideways.count)
    }

    @Test func switchingBackResumesTheFirstAxis() {
        var control = quarterStepControl()
        _ = drag(&control, through: line(from: Vec2(0.5, 0.5), to: Vec2(0.5, 0.63)))
        _ = drag(&control, through: line(from: Vec2(0.5, 0.63), to: Vec2(0.37, 0.63)))
        let down = drag(&control, through: line(from: Vec2(0.37, 0.63), to: Vec2(0.37, 0.50)))
        #expect(control.axis == .vertical)
        #expect(!down.isEmpty)
        #expect(down.allSatisfy { $0 == .init(target: .volume, delta: -1) })
    }

    @Test func smallWobbleInsideTheDeadbandDoesNothing() {
        var control = PinchAxisControl()
        let steps = drag(&control, through: line(from: Vec2(0.5, 0.5), to: Vec2(0.51, 0.51)))
        #expect(steps.isEmpty)
        #expect(control.axis == nil)
    }

    @Test func reversingEmitsNegativeSteps() {
        var control = quarterStepControl()
        let up = drag(&control, through: line(from: Vec2(0.5, 0.5), to: Vec2(0.5, 0.63)))
        let down = drag(&control, through: line(from: Vec2(0.5, 0.63), to: Vec2(0.5, 0.52)))
        #expect(up.map(\.delta) == [1, 1])
        #expect(down.map(\.delta) == [-1, -1])
    }

    @Test func totalsAreNetStepsAndClearOnRelease() {
        var control = quarterStepControl()
        _ = drag(&control, through: line(from: Vec2(0.5, 0.5), to: Vec2(0.5, 0.63)))
        #expect(control.total(for: .volume) == 2)
        _ = drag(&control, through: line(from: Vec2(0.5, 0.63), to: Vec2(0.5, 0.52)))
        #expect(control.total(for: .volume) == 0)
        _ = drag(&control, through: line(from: Vec2(0.5, 0.52), to: Vec2(0.5, 0.63)))
        _ = control.update(pinching: false, anchor: Vec2(0.5, 0.63), handSize: Self.handSize)
        #expect(control.totals.isEmpty)
    }

    @Test func releasingResets() {
        var control = quarterStepControl()
        _ = drag(&control, through: line(from: Vec2(0.5, 0.5), to: Vec2(0.5, 0.63)))
        #expect(control.update(pinching: false, anchor: Vec2(0.5, 0.63), handSize: Self.handSize).isEmpty)
        #expect(control.isEngaged == false)
        #expect(control.axis == nil)
    }
}
