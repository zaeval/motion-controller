import Foundation
import Testing
@testable import GestureCore

struct StrangerWatchTests {
    /// Checks a face of `similarity` `count` times, a quarter second apart, as the face checks run.
    private func check(
        _ watch: inout StrangerWatch, similarity: Double?, count: Int, from start: TimeInterval,
        faceHeight: Double = 0.2
    ) -> [Bool] {
        (0..<count).map { step in
            watch.faceChecked(similarity: similarity, faceHeight: faceHeight, at: start + Double(step) * 0.25)
        }
    }

    /// The bot Mac, 2026-09-23: a stranger's face at 0.20–0.36 six checks running, with the owner out of view.
    @Test func aFaceMatchingNobodyLocksAfterFiveChecks() {
        var watch = StrangerWatch()
        #expect(check(&watch, similarity: 0.28, count: 4, from: 10) == [false, false, false, false])
        #expect(watch.checksAgainst == 4)
        let locked = watch.faceChecked(similarity: 0.25, faceHeight: 0.1, at: 11)
        #expect(locked)
        #expect(watch.checksAgainst == 0)
    }

    @Test func nobodyIsCheckedWhileTheOwnerIsThere() {
        var watch = StrangerWatch()
        // The owner at the screen: faces behind them, or theirs misread, count for nothing...
        _ = watch.faceChecked(similarity: 0.7, faceHeight: 0.3, at: 0)
        #expect(check(&watch, similarity: 0.2, count: 8, from: 0.25).allSatisfy { !$0 })
        #expect(watch.checksAgainst == 0)
        #expect(watch.ownerIsThere(at: 2))
        // ...and once they have been out of view a while, the stranger still there is counted.
        #expect(check(&watch, similarity: 0.2, count: 5, from: 3.25) == [false, false, false, false, true])
    }

    /// The user's call (2026-09-23): the owner and somebody else together, then the owner's face goes — lock.
    @Test func togetherThenTheOwnersFaceGoesAndItLocks() {
        var watch = StrangerWatch()
        var time = 0.0
        var locked: Double?
        // Both in view for ten seconds: the owner's face in most checks, the other one's in between.
        while time < 10 {
            _ = watch.faceChecked(similarity: Int(time * 4) % 3 == 0 ? 0.25 : 0.65, faceHeight: 0.25, at: time)
            time += 0.25
        }
        // The owner leaves; the other face stays.
        while time < 20, locked == nil {
            if watch.faceChecked(similarity: 0.25, faceHeight: 0.25, at: time) { locked = time }
            time += 0.25
        }
        // The owner's face was last seen at 9.5: three seconds of vouching, then five checks from 12.5.
        #expect(locked == 13.5)
    }

    @Test func theOwnerTurningUpWipesTheCount() {
        var watch = StrangerWatch()
        _ = check(&watch, similarity: 0.3, count: 4, from: 0)
        _ = watch.faceChecked(similarity: 0.6, faceHeight: 0.3, at: 1)
        #expect(watch.checksAgainst == 0)
    }

    /// The bot Mac's camera puts its owner at 0.41–0.45 on a bad frame: not enough to vouch, and not a stranger.
    @Test func aFaceInTheBandBelowTheBarCountsForNothing() {
        var watch = StrangerWatch()
        #expect(check(&watch, similarity: 0.42, count: 12, from: 0).allSatisfy { !$0 })
        #expect(watch.checksAgainst == 0)
    }

    @Test func noFaceOrOneTooFarAwayNeverLocks() {
        var watch = StrangerWatch()
        #expect(check(&watch, similarity: nil, count: 12, from: 0).allSatisfy { !$0 })
        #expect(check(&watch, similarity: 0.1, count: 12, from: 3, faceHeight: 0.05).allSatisfy { !$0 })
        #expect(watch.checksAgainst == 0)
    }

    @Test func facesSpreadOutPastTheWindowDoNotAddUp() {
        var watch = StrangerWatch()
        // One stranger reading every two seconds: never five within five seconds.
        for step in 0..<10 {
            let locked = watch.faceChecked(similarity: 0.2, faceHeight: 0.2, at: Double(step) * 2)
            #expect(!locked)
        }
        #expect(watch.checksAgainst <= 3)
    }

    @Test func touchIDBuysPeaceAndAnEnrolledFaceEndsItEarly() {
        var watch = StrangerWatch()
        watch.quiet(from: 0)
        #expect(watch.isQuiet(at: 60))
        #expect(check(&watch, similarity: 0.2, count: 20, from: 1).allSatisfy { !$0 })
        // Past the quiet, a stranger makes the whole count.
        #expect(check(&watch, similarity: 0.2, count: 5, from: 121) == [false, false, false, false, true])

        watch.quiet(from: 200)
        _ = watch.faceChecked(similarity: 0.6, faceHeight: 0.3, at: 201)
        #expect(!watch.isQuiet(at: 202))
        // The owner who ended the quiet is still vouching; gone a while, the count starts.
        #expect(check(&watch, similarity: 0.2, count: 5, from: 205) == [false, false, false, false, true])
    }

    @Test func resettingForgetsEverything() {
        var watch = StrangerWatch()
        _ = watch.faceChecked(similarity: 0.7, faceHeight: 0.3, at: 0)
        watch.quiet(from: 0)
        _ = check(&watch, similarity: 0.2, count: 3, from: 0.5)
        watch.reset()
        #expect(watch.checksAgainst == 0)
        #expect(!watch.isQuiet(at: 1))
        #expect(!watch.ownerIsThere(at: 1))
    }
}
