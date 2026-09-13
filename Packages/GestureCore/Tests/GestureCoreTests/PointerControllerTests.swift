import Foundation
import Testing
@testable import GestureCore

struct PointerControllerTests {
    private static let frame = 1.0 / 30
    /// 20% margins all round: camera 0.2...0.8 spans a screen of scroll travel.
    private static let box = InteractionBox(left: 0.2, right: 0.2, top: 0.2, bottom: 0.2)
    private static let start = Vec2(0.3, 0.4)

    /// Relative mapping, unfiltered, one gain at every speed, square screen: 0.01 of camera travel at hand size 0.1
    /// moves the cursor 0.02 of the screen. The press, tap and scroll machinery it drives is the same either way.
    private func relativeController() -> PointerController {
        var settings = PointerController.Settings()
        settings.mapping = .relative
        settings.box = Self.box
        settings.filter = OneEuroFilter.Params(minCutoff: 1e6, beta: 0, dCutoff: 1)
        settings.slowGain = 0.2
        settings.fastGain = 0.2
        settings.screenAspect = 1
        settings.stillDeadband = 0.001
        return PointerController(settings: settings)
    }

    /// Absolute mapping, unfiltered: camera 0.2...0.8 spans the screen in both axes.
    private func absoluteController() -> PointerController {
        var settings = PointerController.Settings()
        settings.box = Self.box
        settings.filter = OneEuroFilter.Params(minCutoff: 1e6, beta: 0, dCutoff: 1)
        return PointerController(settings: settings)
    }

    private func sample(
        _ x: Double, _ y: Double, pinching: Bool = false, scroll: Bool = false, tap: FingerTap? = nil,
        holdStill: Bool = false, fist: Bool = false, engaged: Bool = true, scale: Double = 0.1
    ) -> PointerController.Sample {
        PointerController.Sample(
            point: Vec2(x, y), handScale: scale, imageAspect: 1, pinching: pinching, scrollPose: scroll,
            tap: tap, holdStill: holdStill, fist: fist, engaged: engaged
        )
    }

    private func isClose(_ a: Vec2?, _ b: Vec2, tolerance: Double = 1e-6) -> Bool {
        guard let a else { return false }
        return a.distance(to: b) <= tolerance
    }

    @Test func handMovesTheCursorFromWhereItIs() {
        var pointer = relativeController()
        #expect(pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start).isEmpty)
        #expect(isClose(pointer.cursor, Self.start))
        // Toward image-left is the user's right; up in the image is up on screen.
        let commands = pointer.update(sample(0.49, 0.51), at: Self.frame, systemCursor: Self.start)
        #expect(commands.count == 1)
        #expect(isClose(commands.first?.movePoint, Vec2(0.32, 0.38)))
    }

    @Test func onlyAnIndexBentTowardTheCameraMovesTheCursor() {
        var pointer = relativeController()
        _ = pointer.update(sample(0.5, 0.5, engaged: false), at: 0, systemCursor: Self.start)
        // Straight: the hand travels, the cursor doesn't.
        #expect(pointer.update(sample(0.4, 0.5, engaged: false), at: Self.frame).isEmpty)
        #expect(isClose(pointer.cursor, Self.start))
        // Bent: zeroed where the hand now is, then the hand moves the cursor.
        #expect(pointer.update(sample(0.4, 0.5), at: 2 * Self.frame).isEmpty)
        let commands = pointer.update(sample(0.39, 0.5), at: 3 * Self.frame)
        #expect(isClose(commands.first?.movePoint, Vec2(0.32, 0.4)))
    }

    @Test func absoluteMappingPutsTheCursorWhereTheHandPoints() {
        var pointer = absoluteController()
        // The box spans the screen: the hand in the middle of it puts the cursor in the middle of the screen.
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        #expect(isClose(pointer.cursor, Vec2(0.5, 0.5)))
        // Toward image-left is the user's right; up in the image is up on screen.
        let commands = pointer.update(sample(0.35, 0.65), at: Self.frame)
        #expect(isClose(commands.first?.movePoint, Vec2(0.75, 0.25), tolerance: 1e-4))
        // Past the box the cursor stops at the screen edge.
        _ = pointer.update(sample(0.05, 0.5), at: 2 * Self.frame)
        #expect(isClose(pointer.cursor, Vec2(1, 0.5), tolerance: 1e-4))
    }

    @Test func aStraightIndexParksTheCursorAndBendingAgainTakesItToTheHand() {
        var pointer = absoluteController()
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        // Straight, then bending for a tap: the hand travels, the cursor stays parked.
        #expect(pointer.update(sample(0.35, 0.5, engaged: false), at: Self.frame).isEmpty)
        #expect(pointer.update(sample(0.35, 0.5, holdStill: true), at: 2 * Self.frame).isEmpty)
        #expect(isClose(pointer.cursor, Vec2(0.5, 0.5)))
        // Bent again: the cursor goes to where the hand is now.
        let commands = pointer.update(sample(0.35, 0.5), at: 3 * Self.frame)
        #expect(isClose(commands.first?.movePoint, Vec2(0.75, 0.5)))
    }

    @Test func aDragFromAParkedCursorFollowsTheHandsOwnTravel() {
        var pointer = absoluteController()
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        // Straightened, and the hand drifted away from where the cursor was parked.
        _ = pointer.update(sample(0.4, 0.5, engaged: false), at: Self.frame)
        var commands = pointer.update(sample(0.4, 0.5, pinching: true, engaged: false), at: 2 * Self.frame)
        for index in 1...4 {
            commands += pointer.update(
                sample(0.4 - 0.01 * Double(index), 0.5, pinching: true, engaged: false),
                at: Double(index + 2) * Self.frame
            )
        }
        let downs = commands.compactMap(\.downPoint)
        #expect(downs.count == 1 && isClose(downs.first, Vec2(0.5, 0.5), tolerance: 1e-4))
        // 0.04 of camera x over a 0.6-wide box, not the 0.1 the hand had already drifted.
        #expect(isClose(commands.compactMap(\.dragPoint).last, Vec2(0.5 + 0.04 / 0.6, 0.5), tolerance: 1e-4))
    }

    @Test func aPinchDragsWithTheIndexStraight() {
        var pointer = relativeController()
        var commands = pointer.update(sample(0.5, 0.5, engaged: false), at: 0, systemCursor: Self.start)
        commands += pointer.update(sample(0.5, 0.5, pinching: true, engaged: false), at: Self.frame)
        for index in 1...5 {
            commands += pointer.update(
                sample(0.5 - 0.01 * Double(index), 0.5, pinching: true, engaged: false), at: Double(index + 1) * Self.frame
            )
        }
        #expect(commands.compactMap(\.downPoint) == [Self.start])
        #expect(!commands.compactMap(\.dragPoint).isEmpty)
    }

    @Test func aHandComingBackIsZeroedWhereItReappears() {
        var pointer = relativeController()
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        _ = pointer.update(sample(0.45, 0.5), at: Self.frame)
        let moved = pointer.cursor!
        #expect(isClose(moved, Vec2(0.4, 0.4)))
        #expect(pointer.update(nil, at: 0.2).isEmpty)
        // Back far to the side after a gap: nothing jumps.
        #expect(pointer.update(sample(0.2, 0.3), at: 0.4, systemCursor: moved).isEmpty)
        #expect(isClose(pointer.cursor, moved))
        _ = pointer.update(sample(0.19, 0.3), at: 0.4 + Self.frame)
        #expect(isClose(pointer.cursor, Vec2(0.42, 0.4)))
    }

    @Test func aStillHandDoesNotWander() {
        var settings = PointerController.Settings()
        settings.mapping = .relative
        settings.box = Self.box
        var pointer = PointerController(settings: settings)
        for index in 0..<150 {
            let jitter = Vec2(0.002 * sin(Double(index) * 1.7), 0.002 * cos(Double(index) * 2.3))
            let still = PointerController.Sample(point: Vec2(0.5, 0.5) + jitter, handScale: 0.15, imageAspect: 16.0 / 9)
            _ = pointer.update(still, at: Double(index) * Self.frame, systemCursor: Self.start)
        }
        #expect(isClose(pointer.cursor, Self.start, tolerance: 0.002))
    }

    @Test func aFasterHandMovesTheCursorFurther() {
        func travel(overFrames frames: Int) -> Double {
            var settings = PointerController.Settings()
            settings.mapping = .relative
            settings.box = Self.box
            settings.filter = OneEuroFilter.Params(minCutoff: 1e6, beta: 0, dCutoff: 1)
            var pointer = PointerController(settings: settings)
            _ = pointer.update(PointerController.Sample(point: Vec2(0.5, 0.5), handScale: 0.1), at: 0, systemCursor: Vec2(0.5, 0.5))
            for index in 1...frames {
                let x = 0.5 - 0.1 * Double(index) / Double(frames)
                _ = pointer.update(PointerController.Sample(point: Vec2(x, 0.5), handScale: 0.1), at: Double(index) * Self.frame)
            }
            return pointer.cursor!.x - 0.5
        }
        // One hand size of travel over a second, then over a tenth of one.
        #expect(travel(overFrames: 3) > 2 * travel(overFrames: 30))
    }

    @Test func accelerationEasesBetweenTheGains() {
        let settings = PointerController.Settings()
        #expect(settings.gain(forSpeed: 0) == settings.slowGain)
        #expect(settings.gain(forSpeed: 100) == settings.fastGain)
        let middle = settings.gain(forSpeed: (settings.slowSpeed + settings.fastSpeed) / 2)
        #expect(abs(middle - (settings.slowGain + settings.fastGain) / 2) < 1e-9)
    }

    @Test func quickPinchClicksWithoutDragging() {
        var pointer = relativeController()
        var commands = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        commands += pointer.update(sample(0.501, 0.5, pinching: true), at: Self.frame)
        commands += pointer.update(sample(0.502, 0.5, pinching: true), at: 2 * Self.frame)
        commands += pointer.update(sample(0.502, 0.5), at: 3 * Self.frame)

        let downs = commands.compactMap(\.downPoint)
        let ups = commands.compactMap(\.upPoint)
        #expect(downs.count == 1)
        #expect(ups.count == 1)
        #expect(isClose(ups.first, downs[0]))
        #expect(!commands.contains { $0.isDrag })
    }

    @Test func pinchAndMoveDragsFromWhereThePinchBegan() {
        var pointer = relativeController()
        var commands = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        commands += pointer.update(sample(0.5, 0.5, pinching: true), at: Self.frame)
        for index in 1...10 {
            commands += pointer.update(sample(0.5 - 0.01 * Double(index), 0.5, pinching: true), at: Double(index + 1) * Self.frame)
        }
        commands += pointer.update(sample(0.4, 0.5), at: 12 * Self.frame)

        #expect(commands.compactMap(\.downPoint) == [Self.start])
        let drags = commands.compactMap(\.dragPoint)
        #expect(drags.count >= 5)
        #expect(isClose(commands.last?.upPoint, drags.last!))
        #expect(!pointer.isPressed)
    }

    @Test func twoQuickPinchesDoubleClick() {
        var pointer = relativeController()
        var commands = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        commands += pointer.update(sample(0.5, 0.5, pinching: true), at: Self.frame)
        commands += pointer.update(sample(0.5, 0.5), at: 2 * Self.frame)
        commands += pointer.update(sample(0.5, 0.5, pinching: true), at: 6 * Self.frame)
        commands += pointer.update(sample(0.5, 0.5), at: 7 * Self.frame)
        #expect(commands.compactMap(\.clickCount) == [1, 1, 2, 2])
    }

    @Test func aPinchHeldStillPressesOnceTheTapWindowPasses() {
        var pointer = relativeController()
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        #expect(pointer.update(sample(0.5, 0.5, pinching: true), at: Self.frame).isEmpty)
        #expect(pointer.update(sample(0.5, 0.5, pinching: true), at: 0.2).isEmpty)
        #expect(pointer.update(sample(0.5, 0.5, pinching: true), at: Self.frame + 0.31) == [.buttonDown(Self.start, clickCount: 1)])
        #expect(pointer.isHoldingButton)
    }

    @Test func aFistClosingThroughAPinchSendsNothing() {
        var pointer = relativeController()
        var commands = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        commands += pointer.update(sample(0.5, 0.5, pinching: true), at: Self.frame)
        commands += pointer.update(sample(0.5, 0.5, pinching: true, fist: true), at: 0.2)
        commands += pointer.update(sample(0.5, 0.5, pinching: true, fist: true), at: 0.5)
        commands += pointer.update(sample(0.5, 0.5, fist: true), at: 0.6)
        #expect(commands.isEmpty)
        #expect(!pointer.isPressed)
    }

    @Test func pinchAlreadyHeldWhenTrackingStartsDoesNotClick() {
        var pointer = relativeController()
        var commands = pointer.update(sample(0.5, 0.5, pinching: true), at: 0, systemCursor: Self.start)
        commands += pointer.update(sample(0.5, 0.5, pinching: true), at: Self.frame)
        commands += pointer.update(sample(0.5, 0.5), at: 2 * Self.frame)
        #expect(commands.isEmpty)
        commands += pointer.update(sample(0.5, 0.5, pinching: true), at: 3 * Self.frame)
        commands += pointer.update(sample(0.5, 0.5), at: 4 * Self.frame)
        #expect(commands.compactMap(\.downPoint).count == 1)
    }

    @Test func lostHandReleasesTheButtonAfterTheGrace() {
        var pointer = relativeController()
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        _ = pointer.update(sample(0.5, 0.5, pinching: true), at: Self.frame)
        _ = pointer.update(sample(0.5, 0.5, pinching: true), at: 0.4)
        #expect(pointer.isHoldingButton)
        #expect(pointer.update(nil, at: 0.7).isEmpty)
        #expect(pointer.isHoldingButton)
        #expect(pointer.update(nil, at: 0.95).compactMap(\.upPoint).count == 1)
        #expect(!pointer.isPressed)
        #expect(pointer.update(nil, at: 1.2).isEmpty)
    }

    @Test func indexTapsClickWhereTheCursorIsAndTwoDoubleClick() {
        var pointer = relativeController()
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        var commands = pointer.update(sample(0.5, 0.5, holdStill: true), at: Self.frame)
        commands += pointer.update(sample(0.5, 0.5, tap: .left), at: 2 * Self.frame)
        commands += pointer.update(sample(0.5, 0.5, holdStill: true), at: 5 * Self.frame)
        commands += pointer.update(sample(0.5, 0.5, tap: .left), at: 6 * Self.frame)
        #expect(commands == [
            .buttonDown(Self.start, clickCount: 1), .buttonUp(Self.start, clickCount: 1),
            .buttonDown(Self.start, clickCount: 2), .buttonUp(Self.start, clickCount: 2),
        ])
    }

    @Test func aTapWithTheMiddleFingerUpRightClicks() {
        var pointer = relativeController()
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        #expect(pointer.update(sample(0.5, 0.5, tap: .right), at: Self.frame) == [.rightClick(Self.start)])
    }

    @Test func theCursorHoldsStillWhileAFingerBends() {
        var pointer = relativeController()
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        #expect(pointer.update(sample(0.45, 0.55, holdStill: true), at: Self.frame).isEmpty)
        // Straight again: zeroed where the palm ended up.
        #expect(pointer.update(sample(0.45, 0.55), at: 2 * Self.frame).isEmpty)
        #expect(isClose(pointer.cursor, Self.start))
    }

    @Test func vSignParksTheCursorAndScrollsWithHandHeight() {
        var pointer = relativeController()
        _ = pointer.update(sample(0.5, 0.5), at: 0, systemCursor: Self.start)
        var commands: [PointerCommand] = []
        for index in 1...3 {
            commands += pointer.update(sample(0.5, 0.5, scroll: true), at: Double(index) * Self.frame)
        }
        #expect(pointer.isScrolling)
        for index in 1...6 {
            commands += pointer.update(sample(0.5, 0.5 + 0.1 * Double(index) / 6, scroll: true), at: Double(index + 3) * Self.frame)
        }
        let scrolls = commands.compactMap(\.scrollAmount)
        #expect(scrolls.allSatisfy { $0 > 0 })
        #expect(abs(scrolls.reduce(0, +) - 0.1 / 0.6) < 1e-3)
        // Leaving the V sign where the hand now is doesn't move the cursor either.
        for index in 10...14 {
            commands += pointer.update(sample(0.5, 0.6), at: Double(index) * Self.frame)
        }
        #expect(!pointer.isScrolling)
        #expect(!commands.contains { $0.movePoint != nil })
        #expect(isClose(pointer.cursor, Self.start))
    }

    @Test func boxFitsTheHandWhileIdleButNeverUnderAPinch() {
        var settings = PointerController.Settings()
        settings.filter = OneEuroFilter.Params(minCutoff: 1e6, beta: 0, dCutoff: 1)
        var pointer = PointerController(settings: settings)
        for index in 0..<60 {
            _ = pointer.update(sample(0.5, 0.5, scale: 0.3), at: Double(index) * Self.frame, systemCursor: Self.start)
        }
        let fitted = InteractionBox.fitted(toHandScale: 0.3)
        #expect(abs(pointer.box.left - fitted.left) < 0.01)
        #expect(abs(pointer.box.top - fitted.top) < 0.02)

        _ = pointer.update(sample(0.5, 0.5, pinching: true, scale: 0.3), at: 60 * Self.frame)
        let pressedBox = pointer.box
        for index in 61..<90 {
            _ = pointer.update(sample(0.5, 0.5, pinching: true, scale: 0.1), at: Double(index) * Self.frame)
        }
        #expect(pointer.box == pressedBox)
    }
}

private extension PointerCommand {
    var movePoint: Vec2? {
        switch self {
        case .move(let point): point
        default: nil
        }
    }

    var downPoint: Vec2? {
        switch self {
        case .buttonDown(let point, _): point
        default: nil
        }
    }

    var upPoint: Vec2? {
        switch self {
        case .buttonUp(let point, _): point
        default: nil
        }
    }

    var dragPoint: Vec2? {
        switch self {
        case .drag(let point): point
        default: nil
        }
    }

    var isDrag: Bool { dragPoint != nil }

    var clickCount: Int? {
        switch self {
        case .buttonDown(_, let count), .buttonUp(_, let count): count
        default: nil
        }
    }

    var scrollAmount: Double? {
        switch self {
        case .scroll(let amount): amount
        default: nil
        }
    }
}
