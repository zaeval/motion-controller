import Foundation
import Testing
@testable import GestureCore

struct StrangerWatchTests {
    /// Checks a face of `similarity` `count` times, a quarter second apart from `start`.
    private func check(
        _ watch: inout StrangerWatch, similarity: Double?, count: Int, from start: TimeInterval = 0,
        faceHeight: Double = 0.2
    ) -> [Bool] {
        var verdicts: [Bool] = []
        for step in 0..<count {
            verdicts.append(watch.faceChecked(
                similarity: similarity, faceHeight: faceHeight, at: start + Double(step) * 0.25
            ))
        }
        return verdicts
    }

    @Test func aFaceMatchingNobodyLocksAfterAFewChecksInARow() {
        var watch = StrangerWatch()
        let verdicts = check(&watch, similarity: 0.1, count: 5)
        #expect(verdicts == [false, false, false, false, true])
        // It fires once; the lock takes over from there.
        #expect(check(&watch, similarity: 0.1, count: 4, from: 2) == [false, false, false, false])
    }

    @Test func anEnrolledFaceStartsTheCountOver() {
        var watch = StrangerWatch()
        #expect(check(&watch, similarity: 0.1, count: 4).allSatisfy { !$0 })
        #expect(check(&watch, similarity: 0.8, count: 1, from: 1) == [false])
        #expect(watch.checksAgainst == 0)
        #expect(check(&watch, similarity: 0.1, count: 4, from: 2).allSatisfy { !$0 })
        #expect(check(&watch, similarity: 0.1, count: 1, from: 3) == [true])
    }

    @Test func aFaceTheCameraCantMakeOutIsNoEvidence() {
        var watch = StrangerWatch()
        #expect(check(&watch, similarity: nil, count: 20).allSatisfy { !$0 })
        #expect(check(&watch, similarity: 0.1, count: 20, from: 6, faceHeight: 0.05).allSatisfy { !$0 })
        #expect(watch.checksAgainst == 0)
    }

    @Test func touchIDBuysPeaceAndAnEnrolledFaceEndsItEarly() {
        var watch = StrangerWatch()
        watch.quiet(from: 0)
        #expect(watch.isQuiet(at: 100))
        #expect(check(&watch, similarity: 0.1, count: 12, from: 1).allSatisfy { !$0 })
        // Past the quiet time it locks again.
        #expect(check(&watch, similarity: 0.1, count: 5, from: 121).last == true)

        var recognized = StrangerWatch()
        recognized.quiet(from: 0)
        _ = recognized.faceChecked(similarity: 0.8, faceHeight: 0.2, at: 1)
        #expect(!recognized.isQuiet(at: 2))
    }

    @Test func resettingForgetsEverything() {
        var watch = StrangerWatch()
        _ = check(&watch, similarity: 0.1, count: 4)
        watch.quiet(from: 0)
        watch.reset()
        #expect(watch.checksAgainst == 0)
        #expect(!watch.isQuiet(at: 1))
        #expect(check(&watch, similarity: 0.1, count: 5, from: 1).last == true)
    }
}
