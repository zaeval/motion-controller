import Foundation
import Testing
@testable import GestureCore

struct TapDetectorTests {
    private static let frame = 1.0 / 30
    private static let straight = [Double?](repeating: 0.9, count: 10)

    /// Feeds index reaches frame by frame (nil drops the frame) and returns every tap.
    private func feed(
        _ detector: inout TapDetector, index: [Double?], middle: Double = 0.3, middleUp: Bool = false,
        middleFollows: Bool = false, middleMissingFrom: Int? = nil, pinching: Bool = false, palmStep: Double = 0,
        palmSpeed: (Int) -> Double = { _ in 0 }, startingAt t0: TimeInterval = 0
    ) -> [FingerTap] {
        index.enumerated().compactMap { offset, reach in
            let time = t0 + Double(offset) * Self.frame
            guard let reach else { return detector.update(nil, at: time) }
            let middleMissing = middleMissingFrom.map { offset >= $0 } ?? false
            let sample = TapDetector.Sample(
                indexReach: reach,
                middleReach: middleMissing ? nil : middleFollows ? middle * reach / 0.9 : middle,
                middleExtended: middleMissing ? nil : middleUp,
                pinching: pinching,
                palm: Vec2(0.5 + palmStep * Double(offset), 0.5),
                handScale: 0.15,
                palmSpeed: palmSpeed(offset)
            )
            return detector.update(sample, at: time)
        }
    }

    @Test func indexBendingAndStraighteningClicksLeft() {
        var detector = TapDetector()
        #expect(feed(&detector, index: Self.straight + [0.5, 0.9] + Self.straight) == [.left])
    }

    @Test func withTheMiddleFingerUpItClicksRight() {
        var detector = TapDetector()
        #expect(feed(&detector, index: Self.straight + [0.55, 0.45, 0.9] + Self.straight, middle: 0.85, middleUp: true) == [.right])
    }

    @Test func bothFingersFlickingIsNotATap() {
        var detector = TapDetector()
        let flick = Self.straight + [0.6, 0.5, 0.9] + Self.straight
        #expect(feed(&detector, index: flick, middle: 0.85, middleUp: true, middleFollows: true).isEmpty)
    }

    @Test func slowFoldsShallowWobblesAndPinchesAreNotTaps() {
        var detector = TapDetector()
        let fold = [Double?](repeating: 0.4, count: 20)
        #expect(feed(&detector, index: Self.straight + fold + Self.straight).isEmpty)
        #expect(feed(&detector, index: Self.straight + [0.75, 0.7, 0.9] + Self.straight, startingAt: 2).isEmpty)
        #expect(feed(&detector, index: Self.straight + [0.5, 0.9] + Self.straight, pinching: true, startingAt: 4).isEmpty)
    }

    @Test func dropoutsBridgeADipButNeverMakeOne() {
        var detector = TapDetector()
        #expect(feed(&detector, index: Self.straight + [0.3, nil, nil, 0.9] + Self.straight) == [.left])
        #expect(feed(&detector, index: Self.straight + [nil, nil, 0.9] + Self.straight, startingAt: 2).isEmpty)
    }

    @Test func aMovingPalmIsNotTapping() {
        var detector = TapDetector()
        #expect(feed(&detector, index: Self.straight + [0.5, 0.5, 0.5, 0.9], palmStep: 0.03).isEmpty)
    }

    @Test func fingersBlurredShortRightAfterASweepAreNotATap() {
        var detector = TapDetector()
        let tap = Self.straight + [0.5, 0.9] + Self.straight
        #expect(feed(&detector, index: tap, palmSpeed: { $0 == 9 ? 2.0 : 0 }).isEmpty)
        #expect(feed(&detector, index: tap, palmSpeed: { $0 == 0 ? 2.0 : 0 }, startingAt: 2) == [.left])
    }

    @Test func aRightTapNeedsTheMiddleFingerSeenUp() {
        var detector = TapDetector()
        let tap = Self.straight + [0.5, 0.9] + Self.straight
        #expect(feed(&detector, index: tap, middle: 0.85, middleUp: true, middleMissingFrom: 10).isEmpty)
    }

    @Test func aFoldedFingerCantTap() {
        var detector = TapDetector()
        let folded = [Double?](repeating: 0.45, count: 10)
        #expect(feed(&detector, index: folded + [0.2, 0.45] + folded).isEmpty)
    }

    @Test func aDipHeldLongerThanATapEndsAndTheFingerRestsThere() {
        var detector = TapDetector()
        let bending = feed(&detector, index: Self.straight + Array(repeating: Double?(0.5), count: 16))
        #expect(bending.isEmpty)
        #expect(!detector.isDipping)
        let straightening = feed(&detector, index: Self.straight, startingAt: 26 * Self.frame)
        #expect(straightening.isEmpty)
    }

    @Test func aHandThatJustAppearedHasNoRestToTapFrom() {
        var detector = TapDetector()
        // Out of a fist into a point: a fist frame and one pointing frame aren't a resting finger.
        #expect(feed(&detector, index: [0.2, 0.66, 0.05, 0.86, 0.9, 0.9]).isEmpty)
    }

    @Test func aPalmSweepingThroughTheDipIsNotATap() {
        var detector = TapDetector()
        let tap = Self.straight + [0.5, 0.9] + Self.straight
        #expect(feed(&detector, index: tap, palmSpeed: { $0 == 11 ? 1.6 : 0 }).isEmpty)
    }
}

struct IdleGestureDetectorTests {
    private static let frame = 1.0 / 30

    private enum Shape { case open, fist, other }

    /// Feeds (shape, hand size) frames (nil drops the frame) and returns the offsets where recognition parked.
    private func feed(_ detector: inout IdleGestureDetector, _ frames: [(Shape, Double)?], startingAt t0: TimeInterval = 0) -> [Int] {
        frames.enumerated().compactMap { offset, frame in
            let sample = frame.map { IdleGestureDetector.Sample(openPalm: $0.0 == .open, fist: $0.0 == .fist, handScale: $0.1) }
            return detector.update(sample, at: t0 + Double(offset) * Self.frame) ? offset : nil
        }
    }

    private func repeated(_ shape: Shape, _ size: Double, _ count: Int) -> [(Shape, Double)?] {
        [(Shape, Double)?](repeating: (shape, size), count: count)
    }

    @Test func palmFoldedIntoAFistAndPulledBackParks() {
        var detector = IdleGestureDetector()
        let frames = repeated(.open, 0.28, 10) + [(.fist, 0.25)] + repeated(.fist, 0.21, 10) + [(.fist, 0.19), (.fist, 0.16), (.fist, 0.16)]
        #expect(feed(&detector, frames) == [23])
    }

    @Test func aGlimpsedPalmAFistShrinkingAtOnceAndOneSmallFrameDoNotPark() {
        // Two frames of open palm is a misread, not a palm shown to park.
        var glimpsed = IdleGestureDetector()
        #expect(feed(&glimpsed, repeated(.open, 0.28, 2) + repeated(.fist, 0.21, 8) + repeated(.fist, 0.15, 3)).isEmpty)
        // Shrinking straight away is the fist still closing, as it does on the way into gesture mode.
        var closing = IdleGestureDetector()
        #expect(feed(&closing, repeated(.open, 0.28, 10) + [(.fist, 0.25), (.fist, 0.21), (.fist, 0.15), (.fist, 0.15)]).isEmpty)
        // A single small frame is tracking noise.
        var blip = IdleGestureDetector()
        #expect(feed(&blip, repeated(.open, 0.28, 10) + repeated(.fist, 0.21, 8) + [(.fist, 0.15), (.fist, 0.21), (.fist, 0.21)]).isEmpty)
    }

    @Test func foldingAloneAFistWithoutAPalmOrAPullTooLateDoNotPark() {
        var detector = IdleGestureDetector()
        // The fold's own drop in measured size doesn't count.
        #expect(feed(&detector, repeated(.open, 0.28, 10) + repeated(.fist, 0.21, 30)).isEmpty)
        #expect(feed(&detector, repeated(.fist, 0.21, 10) + [(.fist, 0.15)], startingAt: 5).isEmpty)
        #expect(feed(&detector, repeated(.open, 0.28, 10) + repeated(.fist, 0.21, 60) + [(.fist, 0.15)], startingAt: 10).isEmpty)
    }

    @Test func briefDropoutsKeepTheGestureButOpeningAbandonsIt() {
        var detector = IdleGestureDetector()
        let dropped = repeated(.open, 0.28, 10) + repeated(.fist, 0.21, 8) + [nil, nil, (.fist, 0.15), (.fist, 0.15)]
        #expect(feed(&detector, dropped) == [21])
        let reopened = repeated(.open, 0.28, 10) + [(.fist, 0.25), (.fist, 0.21), (.open, 0.28), (.other, 0.2), (.fist, 0.15)]
        #expect(feed(&detector, reopened, startingAt: 5).isEmpty)
    }
}
