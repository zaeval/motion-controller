import Foundation
import Testing
@testable import GestureCore

struct ScreenPresenceTests {
    private static let frame = 1.0 / 30

    /// Feeds `seconds` of frames from `start`; returns every state change in order.
    private func feed(
        _ presence: inout ScreenPresence, from start: TimeInterval, seconds: TimeInterval, present: Bool
    ) -> [ScreenPresence.State] {
        (0..<Int((seconds / Self.frame).rounded())).compactMap { index in
            presence.update(personPresent: present, at: start + Double(index) * Self.frame)
        }
    }

    @Test func staysAwakeWhileSomeoneIsThereAndDimsTenSecondsAfterTheyLeave() {
        var presence = ScreenPresence()
        #expect(feed(&presence, from: 0, seconds: 600, present: true) == [.awake])
        #expect(feed(&presence, from: 600, seconds: 9.5, present: false).isEmpty)
        #expect(feed(&presence, from: 609.5, seconds: 1, present: false) == [.dimmed])
        #expect(feed(&presence, from: 610.5, seconds: 300, present: false).isEmpty)
    }

    /// The user's call (2026-09-14): recognition parks after 5 s, the screen goes dark after 10 s, on the same clock.
    @Test func dimsFiveSecondsAfterAbsenceParksRecognition() throws {
        var presence = ScreenPresence()
        var modes = ModeController()
        var dimmedAt: TimeInterval?
        var parkedAt: TimeInterval?
        for index in 0..<(20 * 30) {
            let time = Double(index) * Self.frame
            let here = time < 1
            if presence.update(personPresent: here, at: time) == .dimmed { dimmedAt = time }
            if modes.update(nil, personPresent: here, at: time) == .idle { parkedAt = time }
        }
        let dimmed = try #require(dimmedAt)
        let parked = try #require(parkedAt)
        #expect(abs(dimmed - parked - 5) < 2 * Self.frame)
    }

    @Test func comingBackWakesOnTheFirstFrameAnyoneIsSeen() {
        var presence = ScreenPresence()
        _ = feed(&presence, from: 0, seconds: 1, present: true)
        #expect(feed(&presence, from: 1, seconds: 30, present: false) == [.dimmed])
        #expect(presence.update(personPresent: true, at: 31) == .awake)
    }

    @Test func unlockingWakesAndStartsTheAbsenceClockOver() {
        var presence = ScreenPresence()
        #expect(feed(&presence, from: 0, seconds: 11, present: false) == [.awake, .dimmed])
        #expect(presence.unlock(at: 11) == .awake)
        #expect(feed(&presence, from: 11, seconds: 9.9, present: false).isEmpty)
        #expect(feed(&presence, from: 20.9, seconds: 0.5, present: false) == [.dimmed])
        #expect(presence.unlock(at: 30) == .awake)
        #expect(presence.unlock(at: 30.1) == nil)
    }

    @Test func aPersonMissedForSecondsAtATimeNeverDims() {
        var presence = ScreenPresence()
        var changes: [ScreenPresence.State] = []
        for cycle in 0..<20 {
            let start = Double(cycle) * 10
            changes += feed(&presence, from: start, seconds: 1, present: true)
            changes += feed(&presence, from: start + 1, seconds: 9, present: false)
        }
        #expect(changes == [.awake])
    }

    @Test func nobodyFromTheStartDimsTenSecondsIn() {
        var presence = ScreenPresence()
        #expect(feed(&presence, from: 100, seconds: 9.9, present: false) == [.awake])
        #expect(feed(&presence, from: 109.9, seconds: 0.5, present: false) == [.dimmed])
    }
}
