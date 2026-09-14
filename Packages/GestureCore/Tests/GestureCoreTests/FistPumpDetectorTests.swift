import Foundation
import Testing
@testable import GestureCore

struct FistPumpDetectorTests {
    private static let frame = 1.0 / 30
    private static let resting = 0.15

    /// Feeds frames at `scale` for `seconds` and returns how many times the gesture fired.
    private func feed(
        _ detector: inout FistPumpDetector, scale: Double, seconds: TimeInterval, from start: TimeInterval,
        anchor: Vec2 = Vec2(0.5, 0.5), fist: Bool = true, openHand: Bool = false
    ) -> Int {
        var fired = 0
        for index in 0...Int((seconds / Self.frame).rounded()) {
            let sample = FistPumpDetector.Sample(
                handScale: scale, anchor: anchor, fist: fist, openHand: openHand
            )
            if detector.update(sample, at: start + Double(index) * Self.frame) { fired += 1 }
        }
        return fired
    }

    /// One push out and back, as a hand moving toward the camera and returning.
    private func pump(
        _ detector: inout FistPumpDetector, from start: TimeInterval, out: Double = 1.25,
        anchor: Vec2 = Vec2(0.5, 0.5)
    ) -> Int {
        var fired = feed(&detector, scale: Self.resting * out, seconds: 0.1, from: start, anchor: anchor)
        fired += feed(&detector, scale: Self.resting, seconds: 0.1, from: start + 0.13, anchor: anchor)
        return fired
    }

    @Test func twoPushesPlayOrPause() {
        var detector = FistPumpDetector()
        // A moment of the palm at rest sets the baseline.
        #expect(feed(&detector, scale: Self.resting, seconds: 0.3, from: 0) == 0)
        #expect(pump(&detector, from: 0.33) == 0)
        #expect(pump(&detector, from: 0.6) == 1)
    }

    @Test func onePushIsNotEnough() {
        var detector = FistPumpDetector()
        _ = feed(&detector, scale: Self.resting, seconds: 0.3, from: 0)
        #expect(pump(&detector, from: 0.33) == 0)
        // Held there afterwards: still one push.
        #expect(feed(&detector, scale: Self.resting, seconds: 1.0, from: 0.6) == 0)
    }

    @Test func pushesTooFarApartAreTwoSeparateMotions() {
        var detector = FistPumpDetector()
        _ = feed(&detector, scale: Self.resting, seconds: 0.3, from: 0)
        #expect(pump(&detector, from: 0.33) == 0)
        // Past the window: the first push has expired, so this is a first push again.
        #expect(feed(&detector, scale: Self.resting, seconds: 1.6, from: 0.6) == 0)
        #expect(pump(&detector, from: 2.3) == 0)
    }

    @Test func aParkNeverPumps() {
        var detector = FistPumpDetector()
        _ = feed(&detector, scale: Self.resting, seconds: 0.4, from: 0)
        // ✊ pulled back: the hand only ever gets smaller, so there is no push to count.
        #expect(feed(&detector, scale: Self.resting * 0.8, seconds: 0.3, from: 0.43) == 0)
        #expect(feed(&detector, scale: Self.resting * 0.5, seconds: 0.5, from: 0.76) == 0)
    }

    /// Opening the hand is the cancel: a palm shown mid-pump is on its way to desktop mode instead.
    @Test func openingTheHandCancelsThePump() {
        var detector = FistPumpDetector()
        _ = feed(&detector, scale: Self.resting, seconds: 0.3, from: 0)
        #expect(pump(&detector, from: 0.33) == 0)
        #expect(feed(&detector, scale: Self.resting, seconds: 0.2, from: 0.6, fist: false, openHand: true) == 0)
        // The second push after that counts as a first one again, so nothing fires.
        #expect(pump(&detector, from: 0.85) == 0)
    }

    @Test func aSweepAcrossTheFrameNeverPumps() {
        var detector = FistPumpDetector()
        _ = feed(&detector, scale: Self.resting, seconds: 0.3, from: 0)
        // The hand leans in as it lifts and then travels sideways: the travel disqualifies it.
        #expect(pump(&detector, from: 0.33, anchor: Vec2(0.5, 0.5)) == 0)
        #expect(pump(&detector, from: 0.6, anchor: Vec2(0.75, 0.5)) == 0)
    }

    @Test func aHandThatGoesMissingStartsOver() {
        var detector = FistPumpDetector()
        _ = feed(&detector, scale: Self.resting, seconds: 0.3, from: 0)
        #expect(pump(&detector, from: 0.33) == 0)
        let firedOnTheGap = detector.update(nil, at: 0.6)
        #expect(!firedOnTheGap)
        // The pump before the gap doesn't count toward the pair.
        _ = feed(&detector, scale: Self.resting, seconds: 0.3, from: 0.63)
        #expect(pump(&detector, from: 0.96) == 0)
    }

    @Test func aSlowReachTowardTheCameraIsNotAPump() {
        var detector = FistPumpDetector()
        // Creeping closer: the baseline follows the hand, so nothing ever reads as a push.
        var fired = 0
        for index in 0...90 {
            let sample = FistPumpDetector.Sample(
                handScale: Self.resting * (1 + 0.004 * Double(index)), anchor: Vec2(0.5, 0.5), fist: true
            )
            if detector.update(sample, at: Double(index) * Self.frame) { fired += 1 }
        }
        #expect(fired == 0)
    }

    @Test func itDoesNotFireTwiceForOneGesture() {
        var detector = FistPumpDetector()
        _ = feed(&detector, scale: Self.resting, seconds: 0.3, from: 0)
        _ = pump(&detector, from: 0.33)
        #expect(pump(&detector, from: 0.6) == 1)
        // A third push right after the pair belongs to the gesture that just fired.
        #expect(pump(&detector, from: 0.9) == 0)
    }
}
