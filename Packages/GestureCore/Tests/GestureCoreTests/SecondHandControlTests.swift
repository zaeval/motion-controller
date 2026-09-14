import Foundation
import Testing
@testable import GestureCore

struct SecondHandControlTests {
    private static let frame = 1.0 / 30

    /// Holds `pose` for `seconds` and returns everything it asked for. `rising` moves the hand up as it goes.
    private func hold(
        _ control: inout SecondHandControl, _ pose: StaticPose?, seconds: TimeInterval, from start: TimeInterval,
        y: Double = 0.5, rising: Double = 0
    ) -> [SecondHandIntent] {
        var intents: [SecondHandIntent] = []
        for index in 0...Int((seconds / Self.frame).rounded()) {
            let sample = SecondHandControl.Sample(
                pose: pose, anchor: Vec2(0.3, y + rising * Double(index) * Self.frame)
            )
            intents += control.update(sample, at: start + Double(index) * Self.frame)
        }
        return intents
    }

    @Test func anIndexClicksOnceEachTimeItIsShown() {
        var control = SecondHandControl()
        #expect(hold(&control, .pointIndex, seconds: 0.5, from: 0) == [.click])
        #expect(control.pose == .pointIndex)
        // Still up: one shape, one click.
        #expect(hold(&control, .pointIndex, seconds: 0.5, from: 0.6).isEmpty)
        // Away and back again is another click.
        #expect(hold(&control, nil, seconds: 0.3, from: 1.2).isEmpty)
        #expect(hold(&control, .pointIndex, seconds: 0.3, from: 1.6) == [.click])
    }

    @Test func twoFingersRightClick() {
        var control = SecondHandControl()
        #expect(hold(&control, .victory, seconds: 0.3, from: 0) == [.rightClick])
        #expect(hold(&control, .pointIndex, seconds: 0.3, from: 0.4) == [.click])
    }

    /// The fist is the drag: down while it is held, up when the hand opens.
    @Test func aFistHoldsTheButtonDown() {
        var control = SecondHandControl()
        #expect(hold(&control, .fist, seconds: 0.3, from: 0) == [.press])
        #expect(control.isPressing)
        #expect(hold(&control, .fist, seconds: 1.0, from: 0.4).isEmpty)
        #expect(hold(&control, .openPalm, seconds: 0.3, from: 1.5) == [.release])
        #expect(!control.isPressing)
    }

    @Test func aHandThatGoesMissingLetsGo() {
        var control = SecondHandControl()
        #expect(hold(&control, .fist, seconds: 0.3, from: 0) == [.press])
        // Within the grace it is still there.
        #expect(control.update(nil, at: 0.45).isEmpty)
        #expect(control.update(nil, at: 0.7) == [.release])
        #expect(!control.isPressing)
        #expect(control.pose == nil)
    }

    @Test func aFlatHandMovingScrolls() {
        var control = SecondHandControl()
        _ = hold(&control, .openPalm, seconds: 0.2, from: 0)
        // A hand going up scrolls up: positive travel, in steps of `scrollStep`.
        let up = hold(&control, .openPalm, seconds: 0.5, from: 0.3, rising: 0.3)
        let steps = up.compactMap { intent -> Double? in
            guard case .scroll(let travel) = intent else { return nil }
            return travel
        }
        #expect(steps.count >= 3)
        #expect(steps.allSatisfy { $0 > 0 })
        // A hand that settles and holds still scrolls nothing.
        var still = SecondHandControl()
        _ = hold(&still, .openPalm, seconds: 0.2, from: 0)
        #expect(hold(&still, .openPalm, seconds: 0.6, from: 0.3).isEmpty)
    }

    @Test func aShapeThatFlickersPastDoesNothing() {
        var control = SecondHandControl()
        _ = hold(&control, nil, seconds: 0.2, from: 0)
        var intents: [SecondHandIntent] = []
        for index in 0..<2 {
            intents += control.update(
                SecondHandControl.Sample(pose: .pointIndex, anchor: Vec2(0.3, 0.5)),
                at: 0.3 + Double(index) * Self.frame
            )
        }
        #expect(intents.isEmpty)
        #expect(control.pose == nil)
    }
}

struct PointerSecondHandTests {
    private func sample(_ x: Double, _ y: Double) -> PointerController.Sample {
        PointerController.Sample(point: Vec2(x, y), handScale: 0.15, engaged: true)
    }

    /// The press goes down at once and the cursor hand's movement becomes a drag, which is the whole point of
    /// holding the button with the other hand.
    @Test func aPressFromTheOtherHandDragsWhatTheCursorHandMoves() {
        var pointer = PointerController()
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Vec2(0.5, 0.5))
        let down = pointer.apply(.press, at: 0.1)
        #expect(down.count == 1)
        if case .buttonDown(_, let clicks)? = down.first {
            #expect(clicks == 1)
        } else {
            Issue.record("no button down: \(down)")
        }
        #expect(pointer.isHoldingButton)
        let moved = pointer.update(sample(0.7, 0.6), at: 0.2)
        #expect(moved.contains { if case .drag = $0 { true } else { false } })
        #expect(!moved.contains { if case .move = $0 { true } else { false } })
        let up = pointer.apply(.release, at: 0.4)
        #expect(up.contains { if case .buttonUp = $0 { true } else { false } })
        #expect(!pointer.isHoldingButton)
    }

    @Test func clicksAndScrollsWaitForAHeldButtonToGo() {
        var pointer = PointerController()
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Vec2(0.5, 0.5))
        _ = pointer.apply(.press, at: 0.1)
        // The other hand is holding the button: its own clicks and scrolls would fight with that.
        #expect(pointer.apply(.click, at: 0.2).isEmpty)
        #expect(pointer.apply(.rightClick, at: 0.3).isEmpty)
        #expect(pointer.apply(.scroll(0.05), at: 0.4).isEmpty)
        _ = pointer.apply(.release, at: 0.5)
        #expect(pointer.apply(.click, at: 0.6).count == 2)
        #expect(pointer.apply(.rightClick, at: 1.2).contains { if case .rightClick = $0 { true } else { false } })
    }

    /// Showing the shape twice quickly is a double-click, the same chaining a tap gets.
    @Test func twoClicksInQuickSuccessionDoubleClick() {
        var pointer = PointerController()
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Vec2(0.5, 0.5))
        _ = pointer.apply(.click, at: 0.1)
        let second = pointer.apply(.click, at: 0.3)
        #expect(second.contains { if case .buttonDown(_, let clicks) = $0 { clicks == 2 } else { false } })
    }

    @Test func scrollGoesTheWayTheHandWent() {
        var pointer = PointerController()
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Vec2(0.5, 0.5))
        #expect(pointer.apply(.scroll(0.04), at: 0.1) == [.scroll(0.04)])
        pointer.settings.invertScroll = true
        #expect(pointer.apply(.scroll(0.04), at: 0.2) == [.scroll(-0.04)])
    }
}
