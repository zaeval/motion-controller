import CoreGraphics
import Foundation
import Testing
@testable import GestureCore

struct FaceMatchingTests {
    private func close(_ a: CGPoint, _ b: CGPoint, within tolerance: Double = 1e-6) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }

    @Test func alignmentUndoesARotatedScaledShiftedFace() throws {
        let placed = CGAffineTransform(translationX: 640, y: 210).rotated(by: 0.3).scaledBy(x: 2.4, y: 2.4)
        let face = FaceAlignment.template.map { $0.applying(placed) }
        let transform = try #require(FaceAlignment.similarity(from: face))
        for (point, target) in zip(face, FaceAlignment.template) {
            #expect(close(point.applying(transform), target, within: 1e-4))
        }
    }

    @Test func alignmentOfTheTemplateItselfChangesNothing() throws {
        let transform = try #require(FaceAlignment.similarity(from: FaceAlignment.template))
        #expect(abs(transform.a - 1) < 1e-9 && abs(transform.b) < 1e-9 && abs(transform.tx) < 1e-9 && abs(transform.ty) < 1e-9)
    }

    @Test func alignmentRefusesPointsWithNoSpread() {
        #expect(FaceAlignment.similarity(from: Array(repeating: CGPoint(x: 5, y: 5), count: 5)) == nil)
        #expect(FaceAlignment.similarity(from: [CGPoint(x: 1, y: 2)]) == nil)
    }

    @Test func fivePointsPutTheLeftmostEyeAndMouthCornerFirst() {
        let points = FaceAlignment.fivePoints(
            eyes: (CGPoint(x: 80, y: 50), CGPoint(x: 40, y: 50)), nose: CGPoint(x: 60, y: 70),
            mouthCorners: (CGPoint(x: 75, y: 90), CGPoint(x: 45, y: 90))
        )
        #expect(points.map(\.x) == [40, 80, 60, 45, 75])
    }

    @Test func visionRegionsGiveTheTipAndTheCornersEvenOnATiltedHead() throws {
        let tilt = CGAffineTransform(translationX: 300, y: 200).rotated(by: 0.5)
        let points = try #require(FaceAlignment.fivePoints(
            pupils: (CGPoint(x: 40, y: 50).applying(tilt), CGPoint(x: 80, y: 50).applying(tilt)),
            noseCrest: [CGPoint(x: 60, y: 55), CGPoint(x: 60, y: 62), CGPoint(x: 61, y: 72)].map { $0.applying(tilt) },
            outerLips: [CGPoint(x: 44, y: 92), CGPoint(x: 60, y: 86), CGPoint(x: 76, y: 92), CGPoint(x: 60, y: 99)]
                .map { $0.applying(tilt) }
        ))
        let expected = [CGPoint(x: 40, y: 50), CGPoint(x: 80, y: 50), CGPoint(x: 61, y: 72), CGPoint(x: 44, y: 92), CGPoint(x: 76, y: 92)]
            .map { $0.applying(tilt) }
        // A 0.5 rad tilt keeps the left eye left of the right one in the image, so the order holds.
        for (point, want) in zip(points, expected) {
            #expect(close(point, want, within: 1e-9))
        }
        #expect(FaceAlignment.fivePoints(pupils: (.zero, .zero), noseCrest: [.zero], outerLips: [.zero, .zero]) == nil)
    }

    @Test func onlyPointsShapedLikeTheFaceTheyCameFromAreAligned() {
        // The template's eyes are 35 px apart; a face box around them is roughly 90 px wide.
        #expect(FaceAlignment.isPlausible(FaceAlignment.template, faceWidth: 90))
        #expect(!FaceAlignment.isPlausible(FaceAlignment.template.map { CGPoint(x: $0.x * 12, y: $0.y * 12) }, faceWidth: 90))
        let squashed = FaceAlignment.template.map { CGPoint(x: $0.x, y: 51 + ($0.y - 51) * 0.2) }
        #expect(!FaceAlignment.isPlausible(squashed, faceWidth: 90))
        #expect(!FaceAlignment.isPlausible(Array(FaceAlignment.template.prefix(4)), faceWidth: 90))
    }

    @Test func aBadFirstSampleIsDroppedAndReplacedOnceTheRestAgree() throws {
        var enrollment = FaceEnrollment()
        let stranger: [Float] = [0, 0, 1]
        let owner: [Float] = [1, 0.1, 0]
        #expect(enrollment.add(stranger, faceHeight: 0.3, at: 0) == .added)
        let outcomes = (1..<enrollment.settings.sampleCount).map {
            enrollment.add(owner, faceHeight: 0.3, at: Double($0) * 0.4)
        }
        #expect(outcomes.allSatisfy { $0 == .added })
        #expect(enrollment.embeddings.count == enrollment.settings.sampleCount - 1)
        #expect(enrollment.add(owner, faceHeight: 0.3, at: 10) == .complete)
        let template = try #require(enrollment.template)
        #expect(!template.embeddings.contains(stranger))
    }

    @Test func droppingOutliersKeepsTheFacesThatAgree() throws {
        let template = try #require(FaceTemplate(embeddings: [[0, 0, 1], [1, 0.1, 0], [1, 0, 0.05], [0.95, 0.05, 0]]))
        #expect(template.droppingOutliers(below: 0.6).embeddings.count == 3)
        let pair = try #require(FaceTemplate(embeddings: [[0, 0, 1], [1, 0, 0]]))
        #expect(pair.droppingOutliers(below: 0.6) == pair)
    }

    @Test func theTemplateComparesAgainstTheMeanDirection() throws {
        let template = try #require(FaceTemplate(embeddings: [[1, 0, 0], [0, 1, 0]]))
        #expect(abs(template.similarity(to: [1, 1, 0]) - 1) < 1e-6)
        #expect(abs(template.similarity(to: [0, 0, 5])) < 1e-6)
        #expect(template.similarity(to: [1, 1]) == 0)
        #expect(FaceTemplate(embeddings: []) == nil)
        #expect(FaceTemplate(embeddings: [[1, 0], [1, 0, 0]]) == nil)
    }

    /// Feeds similarities in order and returns whether each one verified.
    private func verdicts(_ verification: inout FaceVerification, _ frames: [(Double?, TimeInterval)]) -> [Bool] {
        frames.map { verification.update(similarity: $0.0, at: $0.1) }
    }

    @Test func verificationNeedsSeveralMatchesCloseTogether() {
        var verification = FaceVerification()
        #expect(verdicts(&verification, [(0.7, 0), (0.7, 0.3), (0.7, 0.6)]) == [false, false, true])
    }

    @Test func aStrangersFaceOrALongGapStartsTheCountOver() {
        var verification = FaceVerification()
        // A stranger in between; then no face for a moment keeps the count.
        let first = verdicts(&verification, [(0.7, 0), (0.7, 0.3), (0.1, 0.6), (0.7, 0.9), (0.7, 1.2), (nil, 1.5), (0.7, 1.8)])
        #expect(first == [false, false, false, false, false, false, true])
        verification.reset()
        // Too long a moment doesn't.
        #expect(verdicts(&verification, [(0.7, 2), (0.7, 2.3), (0.7, 4)]) == [false, false, false])
    }

    @Test func enrollmentTakesSpacedSamplesOfABigEnoughConsistentFace() throws {
        var enrollment = FaceEnrollment()
        let owner: [Float] = [1, 0.1, 0]
        let samples: [([Float], Double, TimeInterval)] = [
            (owner, 0.05, 0), (owner, 0.3, 0), (owner, 0.3, 0.1), (owner, 0.3, 0.4), (owner, 0.3, 0.8), ([0, 0, 1], 0.3, 1.2),
        ]
        let outcomes = samples.map { enrollment.add($0.0, faceHeight: $0.1, at: $0.2) }
        #expect(outcomes == [.tooSmall, .added, .tooSoon, .added, .added, .inconsistent])
        var time = 1.2
        var outcome = FaceEnrollment.Outcome.added
        while outcome == .added {
            outcome = enrollment.add(owner, faceHeight: 0.3, at: time)
            time += 0.4
        }
        #expect(outcome == .complete)
        #expect(enrollment.progress == 1)
        let template = try #require(enrollment.template)
        #expect(template.embeddings.count == enrollment.settings.sampleCount)
    }
}
