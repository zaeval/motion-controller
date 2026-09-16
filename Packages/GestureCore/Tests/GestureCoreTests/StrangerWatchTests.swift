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

    /// An empty room, then somebody in it: the state every test starts from. Returns when they turned up.
    private func somebodyArrives(_ watch: inout StrangerWatch) -> TimeInterval {
        feed(&watch, present: true, seconds: 1, from: 0)
        feed(&watch, present: false, seconds: 4, from: 1)
        feed(&watch, present: true, seconds: 0.2, from: 5)
        return 5
    }

    /// Checks a face that matches nobody `count` times, a quarter second apart.
    private func strangerChecks(
        _ watch: inout StrangerWatch, count: Int, from start: TimeInterval, faceHeight: Double = 0.2
    ) -> [Bool] {
        (0..<count).map { watch.faceChecked(similarity: 0.1, faceHeight: faceHeight, at: start + Double($0) * 0.25) }
    }

    @Test func aFaceMatchingNobodyAfterAnEmptyRoomLocks() {
        var watch = StrangerWatch()
        let arrived = somebodyArrives(&watch)
        #expect(watch.isVetting)
        let verdicts = strangerChecks(&watch, count: 4, from: arrived)
        #expect(verdicts == [false, false, false, true])
        // It fires once: the lock takes over from here.
        #expect(!watch.isVetting)
        #expect(strangerChecks(&watch, count: 4, from: arrived + 2) == [false, false, false, false])
    }

    @Test func whoeverWasAlreadyThereIsNeverChecked() {
        var watch = StrangerWatch()
        feed(&watch, present: true, seconds: 30, from: 0)
        #expect(!watch.isVetting)
        #expect(strangerChecks(&watch, count: 6, from: 30).allSatisfy { !$0 })
        // A blink of absence is not an empty room either.
        feed(&watch, present: false, seconds: 1, from: 31)
        feed(&watch, present: true, seconds: 1, from: 32)
        #expect(!watch.isVetting)
    }

    @Test func anEnrolledFaceEndsTheVettingAndAStrangerAfterThemDoesNothing() {
        var watch = StrangerWatch()
        let arrived = somebodyArrives(&watch)
        let enrolled = watch.faceChecked(similarity: 0.8, faceHeight: 0.2, at: arrived)
        #expect(!enrolled)
        #expect(!watch.isVetting)
        #expect(strangerChecks(&watch, count: 6, from: arrived + 0.5).allSatisfy { !$0 })
    }

    @Test func noFaceOrOneTooFarAwayNeverLocks() {
        var watch = StrangerWatch()
        let arrived = somebodyArrives(&watch)
        var unseen: [Bool] = []
        for step in 0..<8 {
            unseen.append(watch.faceChecked(similarity: nil, faceHeight: 0, at: arrived + Double(step) * 0.25))
        }
        #expect(unseen.allSatisfy { !$0 })
        #expect(strangerChecks(&watch, count: 8, from: arrived + 2, faceHeight: 0.04).allSatisfy { !$0 })
        #expect(watch.isVetting)
    }

    @Test func vettingGivesUpAfterItsWindowAndLeavingAgainStopsIt() {
        var watch = StrangerWatch()
        let arrived = somebodyArrives(&watch)
        feed(&watch, present: true, seconds: 11, from: arrived)
        #expect(!watch.isVetting)
        #expect(strangerChecks(&watch, count: 4, from: arrived + 11).allSatisfy { !$0 })

        // Away long enough and back: checked again.
        feed(&watch, present: false, seconds: 4, from: arrived + 12)
        feed(&watch, present: true, seconds: 0.2, from: arrived + 16)
        #expect(watch.isVetting)
        #expect(strangerChecks(&watch, count: 4, from: arrived + 16).last == true)
    }

    @Test func resettingForgetsEverything() {
        var watch = StrangerWatch()
        _ = somebodyArrives(&watch)
        watch.reset()
        #expect(!watch.isVetting)
        #expect(strangerChecks(&watch, count: 4, from: 6).allSatisfy { !$0 })
    }
}
