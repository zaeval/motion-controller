import Foundation
import Testing
@testable import GestureCore

struct GestureAnalyzerTests {
    private static let frame = 1.0 / 30

    @Test func openPalmHeldThenSweptAcrossFiresOneSwipeAndNoPose() {
        var analyzer = GestureAnalyzer()
        var swipes: [SwipeDirection] = []
        var sawPinch = false
        // Twelve frames held still, ten of travel, then still again.
        for index in 0...40 {
            let time = Double(index) * Self.frame
            // Wrist travels image-right fast: the user's left.
            let travel = 0.035 * Double(min(max(index - 12, 0), 9))
            let hand = SyntheticHand.make(.init(), wrist: Vec2(0.30 + travel, 0.5), time: time)
            let reading = analyzer.update(hand: hand, at: time)
            if let swipe = analyzer.lastSwipe { swipes.append(swipe) }
            sawPinch = sawPinch || (reading?.isPinching ?? false)
        }
        #expect(swipes == [.left])
        #expect(!sawPinch)
    }

    @Test func pinchRaisedAndLiftedStepsVolume() {
        var analyzer = GestureAnalyzer()
        var steps: [PinchAxisControl.Step] = []
        for index in 0...40 {
            let time = Double(index) * Self.frame
            let lift = index < 5 ? 0 : 0.004 * Double(index - 5)
            let hand = SyntheticHand.make(.init(middle: false, ring: false, little: false, pinch: true), wrist: Vec2(0.5, 0.45 + lift), time: time)
            steps += analyzer.update(hand: hand, at: time)?.steps ?? []
        }
        #expect(!steps.isEmpty)
        #expect(steps.allSatisfy { $0 == .init(target: .volume, delta: 1) })
    }

    @Test func threeFingersRaisedZoomInOneStepAtATime() {
        var analyzer = GestureAnalyzer()
        var zoomSteps: [Int] = []
        for index in 0...40 {
            let time = Double(index) * Self.frame
            let lift = index < 6 ? 0 : 0.01 * Double(index - 6)
            let hand = SyntheticHand.make(.init(thumb: .curled, little: false), wrist: Vec2(0.5, 0.35 + lift), time: time)
            if let step = analyzer.update(hand: hand, at: time)?.zoomStep, step != 0 {
                zoomSteps.append(step)
            }
        }
        // 0.34 of lift is nine strides of 0.25 × 0.15, each stepping once the stride is complete.
        #expect(zoomSteps.count >= 3)
        #expect(zoomSteps.allSatisfy { $0 == 1 })
    }

    @Test func raisingTheHandIsNotRequiredButTheGateIsStillAvailable() throws {
        let low = SyntheticHand.make(.init(), wrist: Vec2(0.5, 0.1))
        var analyzer = GestureAnalyzer()
        let ungated = analyzer.update(hand: low, at: 0)
        #expect(try #require(ungated).inActiveRegion)

        var settings = GestureAnalyzer.Settings()
        settings.activeRegionMinY = 0.35
        var gated = GestureAnalyzer(settings: settings)
        let update = gated.update(hand: low, at: 0)
        let reading = try #require(update)
        #expect(!reading.inActiveRegion)
        #expect(reading.pose == .openPalm)
    }
}
