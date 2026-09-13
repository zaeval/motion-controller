import Foundation
import Testing
@testable import GestureCore

/// Replays swipes recorded with the debug preview's "3초 녹화" button through the analyzer.
struct SwipeFixtureTests {
    struct Recording {
        let name: String
        let frames: [PoseFrame]
    }

    static func recordings(containing label: String) throws -> [Recording] {
        let directory = Bundle.module.resourceURL!.appending(path: "Fixtures/sequences")
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            // Swift's contains("") is false, so an empty label has to mean everything on purpose.
            .filter { label.isEmpty || $0.lastPathComponent.contains(label) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { Recording(name: $0.lastPathComponent, frames: try JSONDecoder().decode([PoseFrame].self, from: Data(contentsOf: $0))) }
    }

    /// The app's `Pipeline.trackedHand`: the right hand if visible, else the largest.
    static func trackedHand(in frame: PoseFrame) -> HandFrame? {
        let hands = frame.allHands.filter { $0.handSize != nil }.sorted { ($0.handSize ?? 0) > ($1.handSize ?? 0) }
        return hands.first { $0.chirality == .right } ?? hands.first
    }

    /// A swipe fires a moment after the stroke stops, so a 3 s clip that ends on the stroke would look like a miss.
    /// The camera keeps running in reality, so the replay keeps feeding empty frames for this long afterwards.
    static let tail: TimeInterval = 0.6

    static func swipes(in recording: Recording) -> [SwipeDirection] {
        timedSwipes(in: recording).map(\.direction)
    }

    /// Every swipe the recording fires, with the seconds into the clip where it fired.
    static func timedSwipes(in recording: Recording) -> [(direction: SwipeDirection, time: TimeInterval)] {
        var analyzer = GestureAnalyzer()
        let start = recording.frames.first?.timestamp ?? 0
        var fired: [(direction: SwipeDirection, time: TimeInterval)] = []
        for frame in recording.frames {
            _ = analyzer.update(hand: trackedHand(in: frame), at: frame.timestamp)
            if let swipe = analyzer.lastSwipe {
                fired.append((swipe, frame.timestamp - start))
            }
        }
        let last = recording.frames.last?.timestamp ?? start
        for step in 1...Int((tail * 30).rounded()) {
            let time = last + Double(step) / 30
            _ = analyzer.update(hand: nil, at: time)
            if let swipe = analyzer.lastSwipe {
                fired.append((swipe, time - start))
            }
        }
        return fired
    }

    @Test func recordedSwipesFireOnlyInTheirDirection() throws {
        // Here the hand turned over instead of travelling: the palm anchor moved 0.045 frame widths, and any threshold
        // that low would also fire on drift. It must still never fire the wrong way.
        let uncaptured: Set<String> = ["20260912-021156-swipe-left.json"]
        // Vision lost the hand from 1.43 s to 1.73 s in this clip, straight through the third stroke, so only two of
        // the three are in the recording at all.
        let untracked = ["20260913-220006-swipe-left-three-times.json": 2]
        let recordings = try Self.recordings(containing: "swipe-")
        #expect(recordings.count == 18)
        for recording in recordings {
            let expected: SwipeDirection = recording.name.contains("swipe-left") ? .left : .right
            let swipes = Self.swipes(in: recording)
            // Firing the wrong way is the failure the user actually sees: it switches the wrong desktop.
            #expect(!swipes.contains(expected.opposite), "\(recording.name) fired \(swipes)")
            guard !uncaptured.contains(recording.name) else { continue }
            let wanted = untracked[recording.name]
                ?? (recording.name.contains("three-times") ? 3 : recording.name.contains("twice") ? 2 : 1)
            #expect(swipes.count == wanted, "\(recording.name) fired \(swipes), wanted \(wanted)")
        }
    }

    /// `PRINT_SWIPE_TRACES=1 swift test --filter SwipeFixtureTests` prints what the analyzer saw on every frame.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRINT_SWIPE_TRACES"] != nil))
    func printTraces() throws {
        for recording in try Self.recordings(containing: "swipe") {
            let start = recording.frames.first?.timestamp ?? 0
            print("=== \(recording.name) aspect \(String(format: "%.3f", recording.frames.first?.imageAspect ?? 0)) frames \(recording.frames.count)")
            var analyzer = GestureAnalyzer()
            var swipes: [SwipeDirection] = []
            for frame in recording.frames {
                let hand = Self.trackedHand(in: frame)
                let reading = analyzer.update(hand: hand, at: frame.timestamp)
                var line = String(format: "%5.2f", frame.timestamp - start)
                let wrists = frame.bodies.map { body in
                    [BodyJoint.leftWrist, .rightWrist].map { joint in
                        body.normalizedPosition(of: joint).map { String(format: "%.2f,%.2f", $0.x, $0.y) } ?? "----,----"
                    }.joined(separator: " ")
                }
                line += " wristsLR[\(wrists.joined(separator: " | "))]"
                if let reading, let pointer = reading.pointer, let hand {
                    let open = HandFeatures(hand)?.isOpenHand == true
                    line += " \(reading.chirality.rawValue.prefix(1))"
                    line += String(format: " p %.3f,%.3f v %.2f", pointer.x, pointer.y, reading.palmSpeed)
                    line += " open \(open ? 1 : 0) reg \(reading.inActiveRegion ? 1 : 0) pin \(reading.isPinching ? 1 : 0)"
                    line += " fingers \(reading.extendedFingers.map { $0 ? "1" : "0" }.joined())"
                    line += " \(reading.pose.map { "\($0)" } ?? "-")"
                    if let swipe = analyzer.lastSwipe {
                        swipes.append(swipe)
                        line += "  <<< SWIPE \(swipe)"
                    }
                } else {
                    line += " no hand"
                }
                print(line)
            }
            print("--- swipes: \(swipes)")
        }
    }
}
