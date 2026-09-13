import Foundation
import Testing
@testable import GestureCore

struct GestureAnalyzerTests {
    private static let frame = 1.0 / 30

    @Test func openPalmSweepingAcrossFiresOneSwipeAndNoPose() {
        var analyzer = GestureAnalyzer()
        var swipes: [SwipeDirection] = []
        var sawPinch = false
        // Ten frames of travel, then the hand holds still: a swipe fires once its stroke has ended.
        for index in 0...30 {
            let time = Double(index) * Self.frame
            // Wrist travels image-right fast: the user's left.
            let hand = SyntheticHand.make(.init(), wrist: Vec2(0.30 + 0.035 * Double(min(index, 9)), 0.5), time: time)
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
