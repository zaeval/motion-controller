import Foundation
import Testing
@testable import GestureCore

struct SceneryHandsTests {

    private func frame(_ hands: [HandFrame], at time: TimeInterval) -> PoseFrame {
        PoseFrame(bodies: [], looseHands: hands, timestamp: time, imageAspect: 1)
    }

    private func hand(at wrist: Vec2, time: TimeInterval) -> HandFrame {
        SyntheticHand.make(.init(), wrist: wrist, time: time)
    }

    /// Feeds `seconds` of 30 fps frames, the hand placed by `wrist`, and returns how many hands each frame kept.
    private func replay(
        _ filter: inout SceneryHands, seconds: TimeInterval, from start: TimeInterval = 0, wrist: (TimeInterval) -> Vec2?
    ) -> [(time: TimeInterval, kept: Int)] {
        stride(from: start, to: start + seconds, by: 1.0 / 30).map { time in
            let hands = wrist(time).map { [hand(at: $0, time: time)] } ?? []
            return (time, filter.update(frame(hands, at: time)).allHands.count)
        }
    }

    @Test func aHandThatNeverMovesGoesAfterFiveSeconds() {
        var filter = SceneryHands()
        let kept = replay(&filter, seconds: 7) { _ in Vec2(0.44, 0.70) }
        #expect(kept.filter { $0.time < 4.9 }.allSatisfy { $0.kept == 1 })
        #expect(kept.filter { $0.time > 5.1 }.allSatisfy { $0.kept == 0 })
        #expect(filter.removedCount == 1)
    }

    /// The phantom's own wobble: a few thousandths of the frame.
    @Test func jitterInsideTheRadiusIsStillStill() {
        var filter = SceneryHands()
        let kept = replay(&filter, seconds: 7) { time in Vec2(0.44 + 0.006 * sin(time * 20), 0.70 + 0.004 * cos(time * 13)) }
        #expect(kept.filter { $0.time > 5.1 }.allSatisfy { $0.kept == 0 })
    }

    @Test func aMovingHandIsNeverTakenOut() {
        var filter = SceneryHands()
        let kept = replay(&filter, seconds: 10) { time in Vec2(0.3 + 0.1 * sin(time), 0.5) }
        #expect(kept.allSatisfy { $0.kept == 1 })
    }

    /// A hand tapping or knocking keeps coming back to one spot. It must not pick up an old track sitting there and
    /// inherit that track's age.
    @Test func aHandGoingToAndFroOverOneSpotIsNeverTakenOut() {
        var filter = SceneryHands()
        let kept = replay(&filter, seconds: 10) { time in Vec2(0.5 + 0.05 * sin(time * 6), 0.5) }
        #expect(kept.allSatisfy { $0.kept == 1 })
    }

    /// Vision returns two hands at most, and a third candidate takes the slot now and then.
    @Test func aStillHandThatDropsOutForAFrameOrTwoKeepsItsAge() {
        var filter = SceneryHands()
        let kept = replay(&filter, seconds: 7) { time in
            Int((time * 30).rounded()) % 10 < 2 ? nil : Vec2(0.44, 0.70)
        }
        #expect(kept.filter { $0.time > 5.1 }.allSatisfy { $0.kept == 0 })
    }

    @Test func aStillHandGoneLongerThanTheGapStartsOver() {
        var filter = SceneryHands()
        _ = replay(&filter, seconds: 6) { _ in Vec2(0.44, 0.70) }
        _ = replay(&filter, seconds: 1.5, from: 6) { _ in nil }
        let back = replay(&filter, seconds: 1, from: 7.5) { _ in Vec2(0.44, 0.70) }
        #expect(back.allSatisfy { $0.kept == 1 })
    }

    @Test func aStillHandAndAMovingOneSideBySide() {
        var filter = SceneryHands()
        var keptMoving: [Bool] = []
        for time in stride(from: 0.0, to: 8, by: 1.0 / 30) {
            let still = hand(at: Vec2(0.44, 0.70), time: time)
            let moving = hand(at: Vec2(0.3 + 0.1 * sin(time * 2), 0.4), time: time)
            let out = filter.update(frame([still, moving], at: time))
            if time > 5.1 {
                keptMoving.append(out.allHands.count == 1 && out.looseHands.first?.normalizedPosition(of: .wrist)?.y == 0.4)
            }
        }
        #expect(keptMoving.allSatisfy { $0 })
    }

    @Test func aBodysHandIsTakenOutOfTheBody() {
        var filter = SceneryHands()
        var last: PoseFrame?
        for time in stride(from: 0.0, to: 6, by: 1.0 / 30) {
            let body = Body(joints: [:], rightHand: hand(at: Vec2(0.44, 0.70), time: time), timestamp: time, imageAspect: 1)
            last = filter.update(PoseFrame(bodies: [body], looseHands: [], timestamp: time, imageAspect: 1))
        }
        #expect(last?.bodies.count == 1)
        #expect(last?.bodies.first?.rightHand == nil)
    }

    // MARK: Recordings

    /// Loops a recording end to end, so a 3 s clip can show what the filter does after 5 s.
    private func looped(_ frames: [PoseFrame], times: Int) -> [PoseFrame] {
        guard let first = frames.first?.timestamp, let last = frames.last?.timestamp else { return [] }
        let period = last - first + 1.0 / 30
        return (0..<times).flatMap { lap in
            frames.map { frame in
                var copy = frame
                copy.timestamp = frame.timestamp - first + Double(lap) * period
                return copy
            }
        }
    }

    /// 2026-11-06: what kept the absence lock from ever firing. Two of these were taken with the user out of view,
    /// and in those nothing that could drive the app is left once the still hand is gone.
    @Test func thePhantomHandInTheUsersRoomIsTakenOut() throws {
        let recordings = try SwipeFixtureTests.recordings(containing: "phantom")
        #expect(recordings.count == 4)
        for recording in recordings {
            var filter = SceneryHands()
            for frame in looped(recording.frames, times: 3) {
                let out = filter.update(frame)
                guard frame.timestamp > 5.5 else { continue }
                let phantom = out.allHands.contains { hand in
                    guard let wrist = hand.normalizedPosition(of: .wrist) else { return false }
                    return abs(wrist.x - 0.44) < 0.05 && abs(wrist.y - 0.70) < 0.05
                }
                #expect(!phantom, "\(recording.name) at \(frame.timestamp)")
                if frame.bodies.isEmpty {
                    #expect(SwipeFixtureTests.trackedHand(in: out) == nil, "\(recording.name) at \(frame.timestamp)")
                }
            }
        }
    }

    /// Every recording of the user's own hands keeps every hand it has.
    @Test func noRecordedHandOfTheUsersIsEverTakenOut() throws {
        let recordings = try SwipeFixtureTests.recordings(containing: "").filter { !$0.name.contains("phantom") }
        #expect(recordings.count > 50)
        for recording in recordings {
            var filter = SceneryHands()
            for frame in recording.frames {
                let out = filter.update(frame)
                #expect(out.allHands.count == frame.allHands.count, "\(recording.name) at \(frame.timestamp)")
            }
        }
    }

    /// The recordings are 3 s long, so the test above can't see past the mark it guards. This one sets the mark at
    /// 2 s: no hand of the user's stays put that long. The stillest are the `cursor-idle` and click clips, still for
    /// 1.5–2 s (1.5 takes frames out of them, 2 takes none), so the 5 s mark leaves two and a half times that.
    @Test func noRecordedHandOfTheUsersStaysStillForTwoSeconds() throws {
        let recordings = try SwipeFixtureTests.recordings(containing: "").filter { !$0.name.contains("phantom") }
        var strict = SceneryHands.Settings()
        strict.stillSeconds = 2
        for recording in recordings {
            var filter = SceneryHands(settings: strict)
            for frame in recording.frames {
                let out = filter.update(frame)
                #expect(out.allHands.count == frame.allHands.count, "\(recording.name) at \(frame.timestamp)")
            }
        }
    }
}
