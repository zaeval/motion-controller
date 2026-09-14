import Foundation
import Testing
@testable import GestureCore

struct IntruderWatchTests {
    /// Feeds events in order and returns every command, flattened.
    private func run(_ watch: inout IntruderWatch, _ events: [(IntruderWatch.Event, TimeInterval)]) -> [IntruderWatch.Command] {
        events.flatMap { watch.update($0.0, at: $0.1) }
    }

    @Test func theOwnerGettingInSoonAfterThrowsThePhotosAway() {
        var watch = IntruderWatch()
        let commands = run(&watch, [
            (.inputHeldBack, 0), (.inputHeldBack, 0.2), (.faceChecked(similarity: 0.2), 0.5),
            (.faceChecked(similarity: 0.3), 1.2), (.faceChecked(similarity: 0.8), 1.5), (.unlocked(byOwner: true), 2),
        ])
        #expect(commands == [.takePhoto, .takePhoto, .discardPhotos])
        #expect(!watch.isWatching)
    }

    @Test func nobodyGettingInKeepsThePhotos() {
        var watch = IntruderWatch()
        #expect(run(&watch, [(.inputHeldBack, 0), (.tick, 14.9)]) == [.takePhoto])
        #expect(run(&watch, [(.tick, 15)]) == [.keepPhotos])
    }

    @Test func anOpenDialogHoldsTheDecisionUntilItClosesStillLocked() {
        var watch = IntruderWatch()
        let commands = run(&watch, [
            (.inputHeldBack, 0), (.dialogShown, 0.1), (.tick, 20), (.tick, 29), (.dialogClosedStillLocked, 30),
        ])
        #expect(commands == [.takePhoto, .keepPhotos])
    }

    @Test func onlyAFewPhotosOfFacesThatArentTheOwners() {
        var watch = IntruderWatch()
        var events: [(IntruderWatch.Event, TimeInterval)] = [(.inputHeldBack, 0)]
        events += (1...8).map { (.faceChecked(similarity: 0.1), Double($0) * 1.1) }
        #expect(run(&watch, events) == [.takePhoto, .takePhoto, .takePhoto])

        var owner = IntruderWatch()
        let ownerEvents: [(IntruderWatch.Event, TimeInterval)] = [
            (.inputHeldBack, 0), (.faceChecked(similarity: 0.6), 1.5), (.faceChecked(similarity: nil), 3),
        ]
        #expect(run(&owner, ownerEvents) == [.takePhoto])
    }

    @Test func noAttemptNoPhotosAndFacesAloneNeverStartOne() {
        var watch = IntruderWatch()
        let commands = run(&watch, [(.faceChecked(similarity: 0.1), 0), (.tick, 20), (.unlocked(byOwner: true), 21)])
        #expect(commands.isEmpty)
    }

    @Test func theLockEndingSomeOtherWayKeepsThemAndKeysRightAfterWait() {
        var watch = IntruderWatch()
        #expect(run(&watch, [(.inputHeldBack, 0), (.unlocked(byOwner: false), 3)]) == [.takePhoto, .keepPhotos])
        #expect(run(&watch, [(.inputHeldBack, 20), (.tick, 40)]).isEmpty)
        #expect(run(&watch, [(.inputHeldBack, 33)]) == [.takePhoto])
    }
}
