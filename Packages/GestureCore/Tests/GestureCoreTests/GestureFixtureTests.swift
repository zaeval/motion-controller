import Foundation
import Testing
@testable import GestureCore

/// Replays the recorded taps, flicks, swipes and parking gestures through the analyzer and the mode controller.
struct GestureFixtureTests {
    /// A swipe-left clip where the hand turned over instead of travelling, so nothing may fire but a switch to the
    /// next desktop would still be a wrong-direction bug.
    static let handTurnedInsteadOfTravelling: Set<String> = ["20260912-021156-swipe-left.json"]

    static func analyze(_ recording: SwipeFixtureTests.Recording) -> [(frame: PoseFrame, reading: GestureReading?)] {
        var analyzer = GestureAnalyzer()
        return recording.frames.map { frame in
            (frame, analyzer.update(hand: SwipeFixtureTests.trackedHand(in: frame), at: frame.timestamp))
        }
    }

    static func taps(in recording: SwipeFixtureTests.Recording) -> [FingerTap] {
        analyze(recording).compactMap(\.reading?.tap)
    }

    /// Replays recordings back to back through one analyzer, as if recorded in one take, and returns the readings of
    /// the last one with their time from its start.
    static func readings(ofLast recordings: [SwipeFixtureTests.Recording]) -> [(time: TimeInterval, reading: GestureReading?)] {
        var analyzer = GestureAnalyzer()
        var offset = 0.0
        var result: [(time: TimeInterval, reading: GestureReading?)] = []
        for (index, recording) in recordings.enumerated() {
            guard let first = recording.frames.first?.timestamp, let last = recording.frames.last?.timestamp else { continue }
            for frame in recording.frames {
                let reading = analyzer.update(hand: SwipeFixtureTests.trackedHand(in: frame), at: frame.timestamp - first + offset)
                if index == recordings.count - 1 {
                    result.append((frame.timestamp - first, reading))
                }
            }
            offset += last - first + 1.0 / 30
        }
        return result
    }

    @Test func recordedTapsClickTheButtonTheyMean() throws {
        func taps(_ name: String) throws -> [FingerTap] {
            Self.taps(in: try #require(try SwipeFixtureTests.recordings(containing: name).first))
        }
        let doubleTap = try taps("030421-left-click")
        #expect(doubleTap.filter { $0 == .left }.count >= 2 && !doubleTap.contains(.right), "\(doubleTap)")
        let singleTap = try taps("030435-left-click")
        #expect(singleTap.contains(.left) && !singleTap.contains(.right), "\(singleTap)")
        for name in ["030353-right-click", "030358-right-click"] {
            let rightTaps = try taps(name)
            #expect(rightTaps.contains(.right) && !rightTaps.contains(.left), "\(name): \(rightTaps)")
        }
        // Nothing but tracking dropouts: a tap has to show up in the landmarks.
        let dropouts = try taps("030431-left-click")
        #expect(dropouts.isEmpty, "\(dropouts)")
    }

    /// The idle clips hold the index straight up; the move clips bend it toward the camera while moving.
    @Test func onlyAnIndexBentTowardTheCameraEngagesTheCursor() throws {
        func bentFrames(_ name: String, from: TimeInterval, to: TimeInterval) throws -> (bent: Int, frames: Int) {
            let recording = try #require(try SwipeFixtureTests.recordings(containing: name).first)
            let start = recording.frames.first?.timestamp ?? 0
            let span = Self.analyze(recording).compactMap { item -> GestureReading? in
                guard let reading = item.reading, (from...to).contains(item.frame.timestamp - start) else { return nil }
                return reading
            }
            return (span.filter(\.isIndexBent).count, span.count)
        }
        for name in ["035843-cursor-idle", "035919-cursor-idle"] {
            let idle = try bentFrames(name, from: 1.0, to: 3.1)
            #expect(idle.bent == 0 && idle.frames > 20, "\(name): \(idle)")
        }
        let moving = try bentFrames("035933-cursor-move", from: 1.6, to: 2.28)
        #expect(Double(moving.bent) >= 0.8 * Double(moving.frames), "\(moving)")
        // 035945 starts already bent, which a hand's first frames can't tell from straight, so it follows 035919's
        // straight index as if in one take.
        let idle = try #require(try SwipeFixtureTests.recordings(containing: "035919-cursor-idle").first)
        let move = try #require(try SwipeFixtureTests.recordings(containing: "035945-cursor-move").first)
        let take = Self.readings(ofLast: [idle, move])
        let rebent = take.filter { (1.7...2.01).contains($0.time) }.compactMap { $0.reading?.isIndexBent }
        let rebentCount = rebent.filter { $0 }.count
        #expect(!rebent.isEmpty && rebentCount * 2 >= rebent.count, "\(rebent)")
        let taps = take.compactMap { $0.reading?.tap }
        #expect(taps.isEmpty, "\(taps)")
    }

    /// In a session the straight reach is learned from whatever the hand did before, usually a pointed ☝️, whose
    /// index reaches further along the palm than a ✌️'s or a resting tap finger's. Taps must still click after it.
    @Test func tapsStillClickAfterAPointedIndexSetTheStraightReach() throws {
        let pointed = try #require(try SwipeFixtureTests.recordings(containing: "035919-cursor-idle").first)
        func taps(_ name: String) throws -> [FingerTap] {
            let clip = try #require(try SwipeFixtureTests.recordings(containing: name).first)
            return Self.readings(ofLast: [pointed, clip]).compactMap { $0.reading?.tap }
        }
        for name in ["030353-right-click", "030358-right-click"] {
            let rightTaps = try taps(name)
            #expect(rightTaps.contains(.right) && !rightTaps.contains(.left), "\(name): \(rightTaps)")
        }
        let doubleTap = try taps("030421-left-click")
        #expect(doubleTap.filter { $0 == .left }.count >= 2, "\(doubleTap)")
        let singleTap = try taps("030435-left-click")
        #expect(singleTap.contains(.left), "\(singleTap)")
    }

    @Test func flicksSwipesParkingAndCursorMovesAreNotTaps() throws {
        for label in ["scroll", "swipe", "IDLE", "cursor"] {
            for recording in try SwipeFixtureTests.recordings(containing: label) {
                let taps = Self.taps(in: recording)
                if recording.name.contains("035933-cursor-move") {
                    // It ends by folding the bent index into a fist and straightening it again before a pinch, which
                    // is exactly a tap's shape.
                    #expect(taps.count <= 1, "\(recording.name) tapped \(taps)")
                } else {
                    #expect(taps.isEmpty, "\(recording.name) tapped \(taps)")
                }
            }
        }
    }

    @Test func onlyAFistPulledBackParks() throws {
        for recording in try SwipeFixtureTests.recordings(containing: "") {
            let parks = Self.analyze(recording).filter { $0.reading?.idleGesture == true }.count
            #expect(parks == (recording.name.contains("IDLE") ? 1 : 0), "\(recording.name) parked \(parks) times")
        }
    }

    /// Replays every recording the way `Pipeline` dispatches: held poses in gesture mode, sweeps in desktop mode,
    /// and nothing at all on the frame a mode changes. Only the swipe recordings may command anything.
    ///
    /// These clips were all recorded before a swipe needed a held palm, so most of them never reach desktop mode and
    /// rightly fire nothing — `SwipeFixtureTests.recordedStrokesFromAHeldPalmSwitchTheRightWay` is what holds the
    /// detector to the strokes themselves. What this guards is the other direction: that a tap, a scroll, a click, a
    /// cursor move or a park never reaches an action.
    @Test func recordedGesturesOnlyFireTheActionsTheyMean() throws {
        for recording in try SwipeFixtureTests.recordings(containing: "") {
            var analyzer = GestureAnalyzer()
            var evaluator = ActionEvaluator()
            var modes = ModeController(mode: .normal)
            var commands: [GestureAction] = []
            func feed(_ hand: HandFrame?, personPresent: Bool, at time: TimeInterval) {
                let reading = analyzer.update(hand: hand, at: time)
                let changed = modes.update(reading, personPresent: personPresent, at: time)
                guard changed == nil else { return }
                switch modes.mode {
                case .normal:
                    commands += evaluator.update(reading, at: time).filter { !$0.isContinuousStep }
                case .desktop:
                    // Mirrors Pipeline: the sweep is all this mode hears.
                    if let swipe = analyzer.lastSwipe {
                        commands += evaluator.update(nil, swipe: swipe, at: time).filter { !$0.isContinuousStep }
                    }
                default: break
                }
            }
            for frame in recording.frames {
                feed(SwipeFixtureTests.trackedHand(in: frame), personPresent: frame.hasPerson, at: frame.timestamp)
            }
            // The camera keeps running past the end of a 3 s clip, and a swipe fires a moment after the stroke stops.
            let last = recording.frames.last?.timestamp ?? 0
            for step in 1...Int((SwipeFixtureTests.tail * 30).rounded()) {
                feed(nil, personPresent: false, at: last + Double(step) / 30)
            }
            let label = "\(recording.name): \(commands)"
            if recording.name.contains("pang") {
                // These takes are of the palm pump, which the fist replaced on the same day: a palm now opens desktop
                // mode, where nothing but the sweep is heard, so they rightly command nothing at all. A fist take is
                // what would guard the gesture itself.
                #expect(commands.isEmpty, "\(label)")
            } else if Self.handTurnedInsteadOfTravelling.contains(recording.name) {
                #expect(!commands.contains { $0 == .desktop(.next) }, "\(label)")
            } else if recording.name.contains("swipe-left") {
                // Recorded before swipes needed a held palm, so they may rightly fire nothing (SwipeFixtureTests).
                #expect(commands.allSatisfy { $0 == .desktop(.previous) }, "\(label)")
            } else if recording.name.contains("swipe-right") {
                #expect(commands.allSatisfy { $0 == .desktop(.next) }, "\(label)")
            } else {
                #expect(commands.isEmpty, "\(label)")
            }
        }
    }

    /// The user's own park held the palm past play/pause's old hold before folding it, and paused their music
    /// (logged 2026-09-14). Play/pause is a pump now and a held palm opens desktop mode, so each recorded park —
    /// replayed with its first palm frame held 1.5 s longer, long enough to reach that mode — must still park, and
    /// must not play, pause or switch a desktop on the way.
    @Test func aParkThatLingersOnThePalmStillOnlyParks() throws {
        let recordings = try SwipeFixtureTests.recordings(containing: "IDLE")
        #expect(!recordings.isEmpty)
        for recording in recordings {
            let frames = recording.frames
            let firstPalm = try #require(
                Self.analyze(recording).firstIndex { $0.reading?.pose == .openPalm }, "\(recording.name)"
            )
            let stretch = 1.5
            var timeline: [(frame: PoseFrame, time: TimeInterval)] = frames[..<firstPalm].map { ($0, $0.timestamp) }
            for step in 0..<Int(stretch * 30) {
                timeline.append((frames[firstPalm], frames[firstPalm].timestamp + Double(step) / 30))
            }
            timeline += frames[firstPalm...].map { ($0, $0.timestamp + stretch) }

            var analyzer = GestureAnalyzer()
            var evaluator = ActionEvaluator()
            var modes = ModeController(mode: .normal)
            var commands: [GestureAction] = []
            var reachedDesktopMode = false
            // Actions as `Pipeline` dispatches them: poses in gesture mode, sweeps in desktop mode, and never on the
            // frame the mode itself changes.
            func feed(_ hand: HandFrame?, personPresent: Bool, at time: TimeInterval) {
                let reading = analyzer.update(hand: hand, at: time)
                let changed = modes.update(reading, personPresent: personPresent, at: time)
                reachedDesktopMode = reachedDesktopMode || modes.mode == .desktop
                guard changed == nil else { return }
                switch modes.mode {
                case .normal: commands += evaluator.update(reading, at: time)
                case .desktop:
                    if let swipe = analyzer.lastSwipe {
                        commands += evaluator.update(nil, swipe: swipe, at: time)
                    }
                default: break
                }
            }
            for (frame, time) in timeline {
                feed(SwipeFixtureTests.trackedHand(in: frame), personPresent: frame.hasPerson, at: time)
            }
            let last = timeline.last?.time ?? 0
            for step in 1...45 {
                feed(nil, personPresent: false, at: last + Double(step) / 30)
            }
            // Otherwise the stretch proves nothing: the palm has to have been out long enough to mean something.
            #expect(reachedDesktopMode, "\(recording.name)")
            #expect(!commands.contains(.media(.playPause)), "\(recording.name): \(commands)")
            // The palm held that long arms a swipe too; folding it to park must not switch desktops.
            #expect(!commands.contains { if case .desktop = $0 { true } else { false } }, "\(recording.name): \(commands)")
            #expect(modes.mode == .idle, "\(recording.name)")
        }
    }

    @Test func recordedGesturesOnlyChangeModesWhenMeantTo() throws {
        for recording in try SwipeFixtureTests.recordings(containing: "") {
            let readings = Self.analyze(recording)
            for start in [InteractionMode.normal, .pointer] {
                var controller = ModeController(mode: start)
                let changes = readings.compactMap {
                    controller.update($0.reading, personPresent: $0.frame.hasPerson, at: $0.frame.timestamp)
                }
                let label = "\(recording.name) from \(start): \(changes)"
                if recording.name.contains("IDLE") {
                    #expect(changes.last == .idle && !changes.contains(.pointer), "\(label)")
                } else if recording.name.contains("left-click"), start == .normal {
                    #expect(changes.allSatisfy { $0 == .pointer }, "\(label)")
                } else if recording.name.contains("pang"), start == .normal {
                    // Holding the palm out before pumping it can open desktop mode, which is why the pump is heard
                    // there too; nothing else may happen.
                    #expect(changes.allSatisfy { $0 == .desktop }, "\(label)")
                } else if recording.name.contains("swipe"), start == .normal {
                    // A palm is how desktop mode is entered now and another gesture's shape is how it hands the hand
                    // back, so these clips may cross between the two; the cursor and idle are what may not happen.
                    #expect(changes.allSatisfy { $0 == .desktop || $0 == .normal }, "\(label)")
                } else {
                    #expect(changes.isEmpty, "\(label)")
                }
            }
        }
    }
}
