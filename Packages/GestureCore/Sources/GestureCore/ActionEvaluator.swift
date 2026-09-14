import Foundation

/// Turns gesture-mode readings into actions: held static poses through their own state machines, pinch travel into
/// volume and brightness steps, three-finger travel into zoom steps, and swipes into desktop switches. Pure, so the
/// recordings can be replayed against it.
///
/// The open palm used to start the parking gesture, and play/pause was held longer than recorded parks held the palm
/// (0.6–0.9 s). That wasn't enough: the user's own park held the palm past the hold and paused their music (logged
/// 2026-09-14). So a completed hold fires only once the palm comes down, and closing it into a fist instead cancels it,
/// which still covers a habitual 🖐 before the fist now that a park is just ✊ pulled back. A pose's hold only advances
/// while the hand is still, which is what keeps a swipe from firing it on the way past, and for a moment after a
/// swipe no pose can fire at all: swiping rotates the hand, and the hand coming back read as a held pose.
public struct ActionEvaluator: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Longer than a parking gesture holds the palm.
        public var openPalm = GestureStateMachine.Timing(candidateFrames: 4, holdSeconds: 1.2, cooldownSeconds: 1.5)
        /// A completed hold fires once its pose has been gone this long without the hand closing into a fist. The
        /// recorded parks went from palm to fist with at most one frame in between.
        public var releaseGrace: TimeInterval = 0.3
        /// Swiping switches desktops. The user's call (2026-09-14, reversing 2026-09-13): toward their left goes to the
        /// next one, the way a page follows the hand that pushes it.
        public var swipesSwitchDesktops = true
        /// No pose fires for this long after a swipe; the hand on its way back isn't a command.
        public var poseCooldownAfterSwipe: TimeInterval = 1.0
        /// No swipe for this long after a zoom step: a zooming hand that drifts sideways isn't switching desktops.
        public var swipeCooldownAfterZoom: TimeInterval = 1.0

        public init() {}
    }

    /// What a held pose does. Fixed until the mapping editor exists (plan M5).
    private static let poseActions: [(pose: StaticPose, action: GestureAction)] = [
        (.openPalm, .media(.playPause)),
    ]

    private struct Mapped: Sendable {
        let pose: StaticPose
        let action: GestureAction
        var machine: GestureStateMachine
        /// Set once the hold completes: the last time the pose was seen, while the action waits for it to end.
        var heldUntil: TimeInterval?
    }

    public var settings: Settings {
        didSet { applySettings() }
    }

    private var mapped: [Mapped]
    private var lastSwipe: TimeInterval = -.infinity
    private var lastZoomStep: TimeInterval = -.infinity

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
        if settings.swipesSwitchDesktops, let swipe, time - lastZoomStep > settings.swipeCooldownAfterZoom {
            lastSwipe = time
            actions.append(.desktop(swipe == .left ? .next : .previous))
            // A swipe starts from the same still palm that plays or pauses: the palm that swept wasn't lowered.
            for index in mapped.indices {
                mapped[index].machine.reset()
                mapped[index].heldUntil = nil
            }
        }
        let justSwiped = time - lastSwipe <= settings.poseCooldownAfterSwipe
        for index in mapped.indices {
            let pose = mapped[index].pose
            let detected = !justSwiped && reading?.pose == pose
            if mapped[index].machine.update(detected: detected, handStill: reading?.isStill ?? false, at: time) {
                mapped[index].heldUntil = time
            }
            guard let heldUntil = mapped[index].heldUntil else { continue }
            if reading?.pose == pose {
                mapped[index].heldUntil = time
            } else if reading?.isFist == true {
                // Folded into a fist: the parking gesture, not a command.
                mapped[index].heldUntil = nil
            } else if time - heldUntil >= settings.releaseGrace {
                mapped[index].heldUntil = nil
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
        // The hand coming back from a swipe often reads as three fingers on the move.
        if reading.zoomStep != 0, !justSwiped {
            lastZoomStep = time
            actions.append(.keyCombo(reading.zoomStep > 0 ? .zoomIn : .zoomOut))
        }
        return actions
    }

    /// The pose holding toward an action, for the overlay's progress bar. A full bar is a completed hold waiting for
    /// the pose to end.
    public func pending(at time: TimeInterval) -> (pose: StaticPose, action: GestureAction, progress: Double)? {
        for item in mapped {
            if item.heldUntil != nil { return (item.pose, item.action, 1) }
            guard case .armed = item.machine.phase else { continue }
            return (item.pose, item.action, item.machine.holdProgress(at: time))
        }
        return nil
    }

    public mutating func reset() {
        for index in mapped.indices {
            mapped[index].machine.reset()
            mapped[index].heldUntil = nil
        }
        lastSwipe = -.infinity
        lastZoomStep = -.infinity
    }

    private mutating func applySettings() {
        for index in mapped.indices {
            mapped[index].machine.timing = Self.timing(for: mapped[index].pose, settings)
        }
    }

    /// The open palm is the only held pose left: three fingers zoom by moving instead of switching apps.
    private static func timing(for pose: StaticPose, _ settings: Settings) -> GestureStateMachine.Timing {
        settings.openPalm
    }
}
