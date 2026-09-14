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

    /// These clips are of the swipe before 2026-09-14, which started from a moving hand; the swipe now needs the palm
    /// held still first, so most of them rightly fire nothing. Whatever they do fire must never be the wrong way.
    @Test func recordedSwipesNeverSwitchTheWrongWay() throws {
        let recordings = try Self.recordings(containing: "swipe-")
        #expect(recordings.count == 18)
        for recording in recordings {
            let expected: SwipeDirection = recording.name.contains("swipe-left") ? .left : .right
            let swipes = Self.swipes(in: recording)
            #expect(!swipes.contains(expected.opposite), "\(recording.name) fired \(swipes)")
        }
    }

    /// Each recorded stroke, replayed with the palm held still where the analyzer first sees it flat and facing the
    /// camera: the gesture as it is made now. `PRINT_HELD_SWIPES=1` prints what each one fired.
    @Test func recordedStrokesFromAHeldPalmSwitchTheRightWay() throws {
        var fired = 0
        var total = 0
        for recording in try Self.recordings(containing: "swipe-") {
            let expected: SwipeDirection = recording.name.contains("swipe-left") ? .left : .right
            guard let swipes = Self.heldSwipes(in: recording) else { continue }
            total += 1
            if swipes.first == expected { fired += 1 }
            #expect(!swipes.contains(expected.opposite), "\(recording.name) fired \(swipes)")
            if ProcessInfo.processInfo.environment["PRINT_HELD_SWIPES"] != nil {
                print("\(recording.name): \(swipes)")
            }
        }
        if ProcessInfo.processInfo.environment["PRINT_HELD_SWIPES"] != nil {
            print("held strokes that switched the right way: \(fired) of \(total)")
        }
    }

    /// The swipes a recording fires when its first slow, flat, camera-facing palm frame is held for half a second
    /// first; nil when no frame qualifies.
    static func heldSwipes(in recording: Recording) -> [SwipeDirection]? {
        var probe = GestureAnalyzer()
        guard let held = recording.frames.firstIndex(where: { frame in
            guard let hand = trackedHand(in: frame), let features = HandFeatures(hand),
                  let reading = probe.update(hand: hand, at: frame.timestamp)
            else { return false }
            return reading.isStill && features.palmFacesCamera == true
                && Finger.allCases.filter { features.isExtended($0) == true }.count >= 3
        }) else { return nil }
        let frames = recording.frames
        let stretch = 0.5
        var timeline: [(frame: PoseFrame, time: TimeInterval)] = []
        for step in 0..<Int(stretch * 30) {
            timeline.append((frames[held], frames[held].timestamp + Double(step) / 30))
        }
        timeline += frames[held...].map { ($0, $0.timestamp + stretch) }
        var analyzer = GestureAnalyzer()
        var swipes: [SwipeDirection] = []
        for (frame, time) in timeline {
            _ = analyzer.update(hand: trackedHand(in: frame), at: time)
            if let swipe = analyzer.lastSwipe { swipes.append(swipe) }
        }
        let last = timeline.last?.time ?? 0
        for step in 1...Int((tail * 30).rounded()) {
            _ = analyzer.update(hand: nil, at: last + Double(step) / 30)
            if let swipe = analyzer.lastSwipe { swipes.append(swipe) }
        }
        return swipes
    }

    /// `PRINT_HELD_REACH=1 swift test --filter printHeldReach` prints, per recording, where the held replay starts and
    /// how far the palm then gets sideways: within the stroke window of first moving, and at most over the clip.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["PRINT_HELD_REACH"] != nil))
    func printHeldReach() throws {
        let settings = SwipeDetector.Settings()
        for recording in try Self.recordings(containing: "swipe-") {
            let start = recording.frames.first?.timestamp ?? 0
            var probe = GestureAnalyzer()
            var path: [(time: TimeInterval, anchor: Vec2, aspect: Double, still: Bool, facing: Bool?, flat: Bool, fist: Bool)] = []
            for frame in recording.frames {
                guard let hand = Self.trackedHand(in: frame), let features = HandFeatures(hand), let anchor = features.anchor,
                      let reading = probe.update(hand: hand, at: frame.timestamp)
                else { continue }
                let flat = Finger.allCases.filter { features.isExtended($0) == true }.count >= 3
                path.append((frame.timestamp - start, anchor, hand.imageAspect, reading.isStill, features.palmFacesCamera, flat, reading.isFist))
            }
            guard let held = path.firstIndex(where: { $0.still && $0.facing == true && $0.flat }) else {
                print("\(recording.name): no held frame; facing \(path.filter { $0.facing == true }.count)/\(path.count), flat \(path.filter(\.flat).count)")
                continue
            }
            let origin = path[held]
            let moved = path[held...].first { $0.anchor.distance(to: origin.anchor) > settings.stillRadius }
            func reach(_ points: ArraySlice<(time: TimeInterval, anchor: Vec2, aspect: Double, still: Bool, facing: Bool?, flat: Bool, fist: Bool)>) -> String {
                guard let far = points.max(by: { abs($0.anchor.x - origin.anchor.x) < abs($1.anchor.x - origin.anchor.x) }) else { return "-" }
                let dx = (far.anchor.x - origin.anchor.x) / far.aspect
                return String(format: "%+.3f at %.2fs (dy %+.3f)", dx, far.time, far.anchor.y - origin.anchor.y)
            }
            let window = moved.map { m in path[held...].filter { $0.time >= m.time && $0.time <= m.time + settings.strokeWindow } } ?? []
            print(String(format: "%@: held %.2fs, moves %@, window reach %@, clip reach %@, facing %d/%d",
                         recording.name, origin.time, moved.map { String(format: "%.2fs", $0.time) } ?? "never",
                         reach(ArraySlice(window)), reach(path[held...]), path.filter { $0.facing == true }.count, path.count))
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
