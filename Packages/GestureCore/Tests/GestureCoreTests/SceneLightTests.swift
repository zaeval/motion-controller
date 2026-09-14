import Foundation
import Testing
@testable import GestureCore

struct SceneLightTests {
    private static let frame = 1.0 / 30

    /// Feeds `seconds` of frames at one luma and returns every verdict change.
    private func feed(
        _ light: inout SceneLight, luma: Double, seconds: TimeInterval, from start: TimeInterval
    ) -> [Bool] {
        var changes: [Bool] = []
        for index in 0...Int((seconds / Self.frame).rounded()) {
            if let change = light.update(luma: luma, at: start + Double(index) * Self.frame) { changes.append(change) }
        }
        return changes
    }

    @Test func aLitRoomIsNeverDark() {
        var light = SceneLight()
        #expect(feed(&light, luma: 0.42, seconds: 10, from: 0).isEmpty)
        #expect(!light.isDark)
    }

    @Test func anUnlitRoomGoesDarkOnceItHolds() {
        var light = SceneLight()
        // Well under the dwell: a blink of darkness decides nothing.
        #expect(feed(&light, luma: 0.04, seconds: 1.0, from: 0).isEmpty)
        #expect(!light.isDark)
        #expect(feed(&light, luma: 0.04, seconds: 1.0, from: 1.1) == [true])
        #expect(light.isDark)
    }

    @Test func lightComingBackNeedsToClearTheHigherMark() {
        var light = SceneLight()
        _ = feed(&light, luma: 0.04, seconds: 2, from: 0)
        #expect(light.isDark)
        // Between the two marks: not dark enough to stay by itself, not bright enough to come back on.
        #expect(feed(&light, luma: 0.13, seconds: 5, from: 3).isEmpty)
        #expect(light.isDark)
        #expect(feed(&light, luma: 0.40, seconds: 2, from: 9) == [false])
        #expect(!light.isDark)
    }

    @Test func aHandOverTheLensDoesNotFlapTheGate() {
        var light = SceneLight()
        var changes: [Bool] = []
        // Half a second of black every two seconds, the way a hand crossing the lens reads.
        for round in 0..<5 {
            changes += feed(&light, luma: 0.02, seconds: 0.5, from: Double(round) * 2)
            changes += feed(&light, luma: 0.40, seconds: 1.4, from: Double(round) * 2 + 0.55)
        }
        #expect(changes.isEmpty)
        #expect(!light.isDark)
    }

    @Test func noFramesHoldTheVerdictRatherThanClearingIt() {
        var light = SceneLight()
        _ = feed(&light, luma: 0.04, seconds: 2, from: 0)
        #expect(light.isDark)
        // The camera stopped: nothing new is known, so nothing changes, however long it is off.
        for index in 0...300 {
            #expect(light.update(luma: nil, at: 3 + Double(index) * Self.frame) == nil)
        }
        #expect(light.isDark)
        light.reset()
        #expect(light.isDark)
        #expect(light.luma == nil)
    }

    @Test func theDwellRestartsWhenTheReadingStopsDisagreeing() {
        var light = SceneLight()
        // Dark for a second, light for a moment, dark again: the second stretch starts the dwell over.
        _ = feed(&light, luma: 0.04, seconds: 1.0, from: 0)
        _ = feed(&light, luma: 0.40, seconds: 0.2, from: 1.1)
        #expect(feed(&light, luma: 0.04, seconds: 1.0, from: 1.4).isEmpty)
        #expect(!light.isDark)
    }
}
