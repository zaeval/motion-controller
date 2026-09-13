import Foundation

public enum InteractionMode: String, Codable, Sendable {
    /// Only the gestures that change modes are recognized.
    case idle
    /// Poses and motions trigger actions.
    case normal
    /// The hand drives the cursor: taps click, a pinch drags, the V sign scrolls.
    case pointer
}

/// What switched the mode, so a change the user didn't mean can be traced.
public enum ModeChangeReason: String, Codable, Sendable {
    /// ☝️ tapped twice.
    case doubleTap
    /// ✊ held.
    case fist
    /// 🖐 folded into ✊ and pulled back.
    case idleGesture
    /// Pointer mode's hand was gone too long.
    case handLost
    /// Nobody was in front of the camera.
    case absence
    /// The menu or the debug preview.
    case menu
}

/// Moves between idle, gesture and pointer modes. The app answers every change by releasing any held mouse button.
///
/// - ☝️ tapped twice → pointer mode, from idle or gesture mode.
/// - ✊ held → gesture mode, from idle or pointer mode. Never while a pinch holds the mouse button, and the fist that
///   just parked recognition has to open (or leave) first.
/// - 🖐 folded into ✊ and pulled back → idle, from gesture or pointer mode.
/// - Nobody in front of the camera for a while → idle, except in pointer mode, where the hand hides the face;
///   pointer mode whose hand has been gone a while → gesture mode, and absence parks it from there.
public struct ModeController: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// A tap folds the hand for a frame or two; a fist has to outlast that.
        public var fist = GestureStateMachine.Timing(candidateFrames: 3, holdSeconds: 0.35, cooldownSeconds: 0.5)
        /// The second of two taps must complete within this long of the first.
        public var doubleTapWindow: TimeInterval = 0.7
        /// Pointer mode falls back to gesture mode once its hand has been gone this long.
        public var handLostExit: TimeInterval = 3.0
        /// Recognition parks once nobody has been in front of the camera this long.
        public var absenceTimeout: TimeInterval = 2.0
        /// A hand gone this long has let go of the fist that parked recognition.
        public var fistReleaseAfterLoss: TimeInterval = 0.3

        public init() {}
    }

    public var settings: Settings {
        didSet { fist.timing = settings.fist }
    }

    public private(set) var mode: InteractionMode
    /// Why `mode` last changed; nil until it has.
    public private(set) var lastChangeReason: ModeChangeReason?
    private var fist: GestureStateMachine
    private var firstTap: TimeInterval?
    private var handLostSince: TimeInterval?
    /// Only a hand seen in pointer mode can time it out, so switching on from the menu leaves time to raise one.
    private var sawHandInPointerMode = false
    private var firstFrame: TimeInterval?
    private var lastPersonSeen: TimeInterval?
    private var parkingFistHeld = false

    public init(settings: Settings = Settings(), mode: InteractionMode = .normal) {
        self.settings = settings
        self.mode = mode
        fist = GestureStateMachine(timing: settings.fist)
    }

    /// One tap has landed and a second would switch to pointer mode.
    public var awaitingSecondTap: Bool { firstTap != nil }

    /// Feeds one frame: the tracked hand's reading (nil when none), whether anyone is in front of the camera, and
    /// whether a pinch is holding the mouse button down. Returns the new mode on the frame it changes.
    public mutating func update(
        _ reading: GestureReading?, personPresent: Bool, holdingButton: Bool = false, at time: TimeInterval
    ) -> InteractionMode? {
        let start = firstFrame ?? time
        firstFrame = start
        if personPresent { lastPersonSeen = time }
        if let tapTime = firstTap, time - tapTime > settings.doubleTapWindow { firstTap = nil }

        // Pointer mode rides out a lost person: the hand in front of the face is exactly what the cursor follows.
        // Its hand going missing drops it to gesture mode, and absence parks from there.
        if mode != .pointer, time - (lastPersonSeen ?? start) >= settings.absenceTimeout {
            _ = fist.update(detected: false, handStill: true, at: time)
            return change(to: .idle, because: .absence)
        }

        guard let reading else {
            _ = fist.update(detected: false, handStill: true, at: time)
            let since = handLostSince ?? time
            handLostSince = since
            if time - since >= settings.fistReleaseAfterLoss { parkingFistHeld = false }
            guard mode == .pointer, sawHandInPointerMode, time - since >= settings.handLostExit else { return nil }
            return change(to: .normal, because: .handLost)
        }
        handLostSince = nil
        if mode == .pointer { sawHandInPointerMode = true }
        if !reading.isFist { parkingFistHeld = false }

        if reading.idleGesture, mode != .idle {
            let changed = change(to: .idle, because: .idleGesture)
            parkingFistHeld = true
            return changed
        }
        if reading.tap == .left, mode != .pointer {
            if firstTap != nil { return change(to: .pointer, because: .doubleTap) }
            firstTap = time
        }
        let fisting = mode != .normal && reading.isFist && !parkingFistHeld && !holdingButton
        return fist.update(detected: fisting, handStill: true, at: time) ? change(to: .normal, because: .fist) : nil
    }

    /// Switches directly: the menu toggle, or recognition turning off. Returns the mode when it changed.
    @discardableResult
    public mutating func set(_ newMode: InteractionMode) -> InteractionMode? {
        change(to: newMode, because: .menu)
    }

    /// Hold progress (0...1) of a fist toward gesture mode, for the overlay.
    public func transitionProgress(at time: TimeInterval) -> Double {
        mode == .normal ? 0 : fist.holdProgress(at: time)
    }

    private mutating func change(to newMode: InteractionMode, because reason: ModeChangeReason) -> InteractionMode? {
        guard newMode != mode else { return nil }
        mode = newMode
        lastChangeReason = reason
        fist.reset()
        firstTap = nil
        handLostSince = nil
        sawHandInPointerMode = false
        return newMode
    }
}
