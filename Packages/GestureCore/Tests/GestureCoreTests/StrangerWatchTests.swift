import Foundation
import Testing
@testable import GestureCore

struct StrangerWatchTests {
    private static let frame = 1.0 / 30

    /// Feeds `seconds` of presence frames from `start`.
    private func feed(_ watch: inout StrangerWatch, present: Bool, seconds: TimeInterval, from start: TimeInterval) {
        for index in 0...Int((seconds / Self.frame).rounded()) {
            watch.update(personPresent: present, at: start + Double(index) * Self.frame)
        }
    }

    /// An empty seat, then somebody in it: where every test starts. Returns when they turned up.
    private func somebodyArrives(_ watch: inout StrangerWatch) -> TimeInterval {
        feed(&watch, present: true, seconds: 1, from: 0)
        feed(&watch, present: false, seconds: 4, from: 1)
        feed(&watch, present: true, seconds: 0.2, from: 5)
        return 5
    }

    /// Checks a face of `similarity` `count` times, a quarter second apart.
    private func check(
        _ watch: inout StrangerWatch, similarity: Double?, count: Int, from start: TimeInterval,
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

    @Test func aFaceMatchingNobodyInAnEmptiedSeatLocks() {
        var watch = StrangerWatch()
        let arrived = somebodyArrives(&watch)
        #expect(watch.isChecking)
        #expect(check(&watch, similarity: 0.1, count: 5, from: arrived) == [false, false, false, false, true])
        // It fires once; the lock takes over from there.
        #expect(!watch.isChecking)
        #expect(check(&watch, similarity: 0.1, count: 5, from: arrived + 2).allSatisfy { !$0 })
    }

    @Test func whoeverWasAlreadySittingThereIsNeverChecked() {
        var watch = StrangerWatch()
        feed(&watch, present: true, seconds: 30, from: 0)
        #expect(!watch.isChecking)
        #expect(check(&watch, similarity: 0.1, count: 8, from: 30).allSatisfy { !$0 })
        // A blink of absence is not an empty seat either: under two seconds and back.
        feed(&watch, present: true, seconds: 2, from: 32)
        feed(&watch, present: false, seconds: 1.5, from: 34)
        feed(&watch, present: true, seconds: 1, from: 35.5)
        #expect(!watch.isChecking)
    }

    @Test func trackingThatBlinksOutForAMomentDoesNotEndTheChecking() {
        var watch = StrangerWatch()
        let arrived = somebodyArrives(&watch)
        #expect(check(&watch, similarity: 0.1, count: 2, from: arrived) == [false, false])
        feed(&watch, present: false, seconds: 1, from: arrived + 0.5)
        feed(&watch, present: true, seconds: 0.2, from: arrived + 1.5)
        #expect(watch.isChecking)
        #expect(check(&watch, similarity: 0.1, count: 3, from: arrived + 1.7) == [false, false, true])
    }

    @Test func anEnrolledFaceEndsTheCheckingAndAStrangerAfterThemDoesNothing() {
        var watch = StrangerWatch()
        let arrived = somebodyArrives(&watch)
        #expect(check(&watch, similarity: 0.8, count: 1, from: arrived) == [false])
        #expect(!watch.isChecking)
        #expect(check(&watch, similarity: 0.1, count: 8, from: arrived + 0.5).allSatisfy { !$0 })
    }

    @Test func noFaceOrOneTooFarAwayNeverLocks() {
        var watch = StrangerWatch()
        let arrived = somebodyArrives(&watch)
        #expect(check(&watch, similarity: nil, count: 8, from: arrived).allSatisfy { !$0 })
        #expect(check(&watch, similarity: 0.1, count: 8, from: arrived + 2, faceHeight: 0.04).allSatisfy { !$0 })
        #expect(watch.isChecking)
    }

    @Test func checkingGivesUpAfterItsWindowAndLeavingAgainStartsItOver() {
        var watch = StrangerWatch()
        let arrived = somebodyArrives(&watch)
        feed(&watch, present: true, seconds: 11, from: arrived)
        #expect(!watch.isChecking)
        #expect(check(&watch, similarity: 0.1, count: 5, from: arrived + 11).allSatisfy { !$0 })

        feed(&watch, present: false, seconds: 4, from: arrived + 12)
        feed(&watch, present: true, seconds: 0.2, from: arrived + 16)
        #expect(watch.isChecking)
        #expect(check(&watch, similarity: 0.1, count: 5, from: arrived + 16).last == true)
    }

    @Test func touchIDBuysPeaceAndAnEnrolledFaceEndsItEarly() {
        var watch = StrangerWatch()
        let arrived = somebodyArrives(&watch)
        watch.quiet(from: arrived)
        #expect(watch.isQuiet(at: arrived + 100))
        #expect(check(&watch, similarity: 0.1, count: 10, from: arrived).allSatisfy { !$0 })

        var recognized = StrangerWatch()
        let back = somebodyArrives(&recognized)
        recognized.quiet(from: back)
        #expect(check(&recognized, similarity: 0.8, count: 1, from: back) == [false])
        #expect(!recognized.isQuiet(at: back + 1))
    }

    @Test func resettingForgetsEverything() {
        var watch = StrangerWatch()
        let arrived = somebodyArrives(&watch)
        watch.reset()
        #expect(!watch.isChecking)
        #expect(check(&watch, similarity: 0.1, count: 5, from: arrived).allSatisfy { !$0 })
    }
}
