import Foundation

/// Turns gesture-mode readings into actions: held static poses through their own state machines, pinch travel into
/// volume and brightness steps, and swipes into desktop switches. Pure, so the recordings can be replayed against it.
///
/// The open palm is also the first half of the parking gesture (🖐 → ✊ → pull back), and recorded parks hold the palm
/// 0.6–0.9 s, so play/pause has to be held clearly longer than that to be unmistakable. A pose's hold only advances
/// while the hand is still, which is what keeps a swipe from firing it on the way past, and for a moment after a
/// swipe no pose can fire at all: swiping rotates the hand, and the hand coming back read as a held pose.
public struct ActionEvaluator: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Longer than a parking gesture holds the palm.
        public var openPalm = GestureStateMachine.Timing(candidateFrames: 4, holdSeconds: 1.2, cooldownSeconds: 1.5)
        public var threeFingers = GestureStateMachine.Timing(candidateFrames: 4, holdSeconds: 0.4, cooldownSeconds: 1.0)
        /// Swiping switches desktops. The user's call (2026-09-13): toward their right goes to the next one.
        public var swipesSwitchDesktops = true
        /// No pose fires for this long after a swipe; the hand on its way back isn't a command.
        public var poseCooldownAfterSwipe: TimeInterval = 1.0

        public init() {}
    }

    /// What a held pose does. Fixed until the mapping editor exists (plan M5).
    private static let poseActions: [(pose: StaticPose, action: GestureAction)] = [
        (.openPalm, .media(.playPause)),
        (.threeFingers, .keyCombo(.commandTab)),
    ]

    private struct Mapped: Sendable {
        let pose: StaticPose
        let action: GestureAction
        var machine: GestureStateMachine
    }

    public var settings: Settings {
        didSet { applySettings() }
    }

    private var mapped: [Mapped]
    private var lastSwipe: TimeInterval = -.infinity

    public init(settings: Settings = Settings()) {
        self.settings = settings
        mapped = Self.poseActions.map {
            Mapped(pose: $0.pose, action: $0.action, machine: GestureStateMachine(timing: Self.timing(for: $0.pose, settings)))
        }
    }

    /// Feeds one frame's reading (nil when no hand was tracked) and the swipe that completed on it, and returns the
    /// actions they fire. The swipe comes separately because it can land on a frame where the hand has already gone.
    public mutating func update(
        _ reading: GestureReading?, swipe: SwipeDirection? = nil, at time: TimeInterval
    ) -> [GestureAction] {
        var actions: [GestureAction] = []
        if settings.swipesSwitchDesktops, let swipe {
            lastSwipe = time
            actions.append(.desktop(swipe == .right ? .next : .previous))
        }
        let justSwiped = time - lastSwipe <= settings.poseCooldownAfterSwipe
        for index in mapped.indices {
            let detected = !justSwiped && reading?.pose == mapped[index].pose
            if mapped[index].machine.update(detected: detected, handStill: reading?.isStill ?? false, at: time) {
                actions.append(mapped[index].action)
            }
        }
        guard let reading else { return actions }
        for step in reading.steps {
            let key: MediaKey = switch (step.target, step.delta > 0) {
            case (.volume, true): .volumeUp
            case (.volume, false): .volumeDown
            case (.brightness, true): .brightnessUp
            case (.brightness, false): .brightnessDown
            }
            actions += Array(repeating: GestureAction.media(key), count: abs(step.delta))
        }
        return actions
    }

    /// The pose holding toward an action, for the overlay's progress bar.
    public func pending(at time: TimeInterval) -> (pose: StaticPose, action: GestureAction, progress: Double)? {
        for item in mapped {
            guard case .armed = item.machine.phase else { continue }
            return (item.pose, item.action, item.machine.holdProgress(at: time))
        }
        return nil
    }

    public mutating func reset() {
        for index in mapped.indices {
            mapped[index].machine.reset()
        }
        lastSwipe = -.infinity
    }

    private mutating func applySettings() {
        for index in mapped.indices {
            mapped[index].machine.timing = Self.timing(for: mapped[index].pose, settings)
        }
    }

    private static func timing(for pose: StaticPose, _ settings: Settings) -> GestureStateMachine.Timing {
        pose == .openPalm ? settings.openPalm : settings.threeFingers
    }
}
