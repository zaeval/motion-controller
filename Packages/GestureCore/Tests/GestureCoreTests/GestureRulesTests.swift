import Foundation
import Testing
@testable import GestureCore

struct GestureRulesTests {
    private func classify(_ shape: SyntheticHand.Shape, chirality: Chirality = .right, pinching: Bool = false) throws -> StaticPose? {
        let features = try #require(HandFeatures(SyntheticHand.make(shape, chirality: chirality)))
        return GestureRules.classify(features, pinching: pinching)
    }

    @Test func openHandSplitsIntoPalmAndBackForBothHands() throws {
        #expect(try classify(.init()) == .openPalm)
        #expect(try classify(.init(palmTowardCamera: false)) == .backOfHand)
        #expect(try classify(.init(), chirality: .left) == .openPalm)
        #expect(try classify(.init(palmTowardCamera: false), chirality: .left) == .backOfHand)
    }

    @Test func fingerPatterns() throws {
        #expect(try classify(.init(thumb: .curled, middle: false, ring: false, little: false)) == .pointIndex)
        #expect(try classify(.init(thumb: .curled, ring: false, little: false)) == .victory)
        #expect(try classify(.init(thumb: .curled, little: false)) == .threeFingers)
        #expect(try classify(.init(thumb: .curled, index: false, middle: false, ring: false)) == .pinky)
    }

    @Test func closedHands() throws {
        let fist = SyntheticHand.Shape(thumb: .curled, index: false, middle: false, ring: false, little: false)
        #expect(try classify(fist) == .fist)
        var thumbsUp = fist
        thumbsUp.thumb = .up
        #expect(try classify(thumbsUp) == .thumbsUp)
    }

    @Test func pinchWinsOverTheFingerPattern() throws {
        #expect(try classify(.init(middle: false, ring: false, little: false, pinch: true), pinching: true) == .pinch)
    }

    @Test func unmappedShapeIsNil() throws {
        // Index and little up ("rock"): no rule claims it.
        #expect(try classify(.init(thumb: .curled, middle: false, ring: false)) == nil)
    }

    @Test func featureReadings() throws {
        let open = try #require(HandFeatures(SyntheticHand.make(.init())))
        #expect(open.isOpenHand)
        #expect(open.extendedFingers == [true, true, true, true, true])
        #expect((open.openness ?? 0) > 0.29)

        let pinch = try #require(HandFeatures(SyntheticHand.make(.init(pinch: true))))
        #expect((pinch.pinchRatio ?? 1) < 0.1)
    }
}
