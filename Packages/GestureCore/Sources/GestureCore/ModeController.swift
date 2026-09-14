import Foundation

public enum InteractionMode: String, Codable, Sendable {
    /// Only the gestures that change modes are recognized.
    case idle
    /// Poses and motions trigger actions.
    case normal
    /// The hand drives the cursor: taps click, a pinch drags, the V sign scrolls.
    case pointer
    /// Sweeping the held palm sideways switches desktops, and nothing else is recognized. The user's call
    /// (2026-09-14): waiting with the palm out to play or pause was the same motion a swipe starts from, so the
    /// wait now opens a mode where only the sweep means anything.
    case desktop
}

/// What switched the mode, so a change the user didn't mean can be traced.
public enum ModeChangeReason: String, Codable, Sendable {
    /// ☝️ tapped twice.
    case doubleTap
    /// ✊ held.
    case fist
    /// 🖐 held still with the palm to the camera.
    case palmHold
    /// Desktop mode saw a gesture that isn't the palm: back to gesture mode, where that gesture means something.
    case otherPose
    /// ✊ pulled back.
    case idleGesture
    /// Pointer mode's hand was gone too long.
    case handLost
    /// Nobody was in front of the camera.
    case absence
    /// The menu or the debug preview.
    case menu
    /// The dark screen locked, and nothing but its unlocking is recognized.
    case screenLocked
}

/// Moves between idle, gesture and pointer modes. The app answers every change by releasing any held mouse button.
///
/// - ☝️ tapped twice → pointer mode, from any mode but pointer.
/// - 🖐 held still → desktop mode, from gesture mode. Its own hold, longer than the swipe's arming hold, so the
///   palm that enters the mode has already armed the first sweep.
/// - ✊ held → gesture mode, from idle, pointer or desktop mode. Never while a pinch holds the mouse button, and the
///   fist that just parked recognition has to open (or leave) first.
/// - ✊ pulled back → idle, from gesture or pointer mode; but not by the fist that just resumed from idle, which has to
///   open first, or lowering it would park again.
/// - Nobody in front of the camera for a while → idle, except in pointer mode, where the hand hides the face;
///   pointer mode whose hand has been gone a while → gesture mode, and absence parks it from there. Desktop mode
///   parks on absence like gesture mode, and its hand going missing does nothing: there is no cursor to strand, and
///   a hand that leaves between two sweeps should find the mode still there.
public struct ModeController: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// A tap folds the hand for a frame or two; a fist has to outlast that.
        public var fist = GestureStateMachine.Timing(candidateFrames: 3, holdSeconds: 0.35, cooldownSeconds: 0.5)
        /// No real hold: a palm opens desktop mode as directly as a fist opens gesture mode (the user's call,
        /// 2026-09-14 — waiting 0.6 s for it felt like being kept out of the mode). Three frames and a hair, so a
        /// single mistracked frame in some other gesture can't flip the mode.
        public var palmHold = GestureStateMachine.Timing(candidateFrames: 3, holdSeconds: 0.05, cooldownSeconds: 0.5)
        /// And the way out: a gesture that isn't the palm sends desktop mode back to gesture mode just as quickly,
        /// because a palm flashing past on the way to three fingers or a pinch would otherwise leave the user in a
        /// mode that hears neither (2026-09-14 — "확대축소 작동 안한다").
        public var otherPose = GestureStateMachine.Timing(candidateFrames: 3, holdSeconds: 0.05, cooldownSeconds: 0.3)
        /// The second of two taps must complete within this long of the first.
        public var doubleTapWindow: TimeInterval = 0.7
        /// Pointer mode falls back to gesture mode once its hand has been gone this long.
        public var handLostExit: TimeInterval = 3.0
        /// Recognition parks once nobody has been in front of the camera this long.
        public var absenceTimeout: TimeInterval = 5.0
        /// A hand gone this long has let go of the fist that parked recognition.
        public var fistReleaseAfterLoss: TimeInterval = 0.3

        public init() {}
    }

    public var settings: Settings {
        didSet {
            fist.timing = settings.fist
            palm.timing = settings.palmHold
            other.timing = settings.otherPose
        }
    }

    public private(set) var mode: InteractionMode
    /// Why `mode` last changed; nil until it has.
    public private(set) var lastChangeReason: ModeChangeReason?
    private var fist: GestureStateMachine
    private var palm: GestureStateMachine
    /// Desktop mode's way back to gesture mode when the hand makes some other gesture's shape.
    private var other: GestureStateMachine
    private var firstTap: TimeInterval?
    private var handLostSince: TimeInterval?
    /// Only a hand seen in pointer mode can time it out, so switching on from the menu leaves time to raise one.
    private var sawHandInPointerMode = false
    private var firstFrame: TimeInterval?
    private var lastPersonSeen: TimeInterval?
    private var parkingFistHeld = false
    /// The fist that just resumed recognition from idle is still closed, and can't park it again.
    private var wakingFistHeld = false

    public init(settings: Settings = Settings(), mode: InteractionMode = .normal) {
        self.settings = settings
        self.mode = mode
        fist = GestureStateMachine(timing: settings.fist)
        palm = GestureStateMachine(timing: settings.palmHold)
        other = GestureStateMachine(timing: settings.otherPose)
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
            _ = palm.update(detected: false, handStill: true, at: time)
            return change(to: .idle, because: .absence)
        }

        guard let reading else {
            _ = fist.update(detected: false, handStill: true, at: time)
            _ = palm.update(detected: false, handStill: true, at: time)
            let since = handLostSince ?? time
            handLostSince = since
            if time - since >= settings.fistReleaseAfterLoss {
                parkingFistHeld = false
                wakingFistHeld = false
            }
            guard mode == .pointer, sawHandInPointerMode, time - since >= settings.handLostExit else { return nil }
            return change(to: .normal, because: .handLost)
        }
        handLostSince = nil
        if mode == .pointer { sawHandInPointerMode = true }
        if !reading.isFist {
            parkingFistHeld = false
            wakingFistHeld = false
        }

        if reading.idleGesture, mode != .idle, !wakingFistHeld {
            let changed = change(to: .idle, because: .idleGesture)
            parkingFistHeld = true
            return changed
        }
        if reading.tap == .left, mode != .pointer {
            if firstTap != nil { return change(to: .pointer, because: .doubleTap) }
            firstTap = time
        }
        // Only from gesture mode: the palm is how the cursor's hand looks between taps, and idle is meant to stay
        // quiet until a fist wakes it.
        // No hold and no stillness: the user asked (2026-09-14) that this mode open as directly as a fist opens
        // gesture mode. A palm is unambiguous — nothing else in gesture mode uses it — and the pump that also starts
        // from a palm is heard in desktop mode too, so arriving there mid-pump costs nothing.
        let palming = mode == .normal && reading.pose == .openPalm && !reading.isFist
        if palm.update(detected: palming, handStill: reading.isStill, at: time) {
            return change(to: .desktop, because: .palmHold)
        }
        // Zoom and the volume/brightness pinch live in gesture mode, so desktop mode hands the hand back as soon as
        // it makes one of their shapes. The fist below is still the deliberate way out.
        let elsewhere: Set<StaticPose> = [.threeFingers, .victory, .pointIndex, .pinch]
        let leaving = mode == .desktop && !reading.isFist && (reading.isPinching || reading.pose.map(elsewhere.contains) == true)
        // Only from a hand that is holding still: a sweeping hand blurs and turns until it reads as a pinch or three
        // fingers, and leaving the mode mid-stroke would swallow the sweep it is in the middle of.
        if other.update(detected: leaving, handStill: reading.isStill, at: time) {
            return change(to: .normal, because: .otherPose)
        }
        let fisting = mode != .normal && reading.isFist && !parkingFistHeld && !holdingButton
        guard fist.update(detected: fisting, handStill: true, at: time) else { return nil }
        let resuming = mode == .idle
        let changed = change(to: .normal, because: .fist)
        wakingFistHeld = resuming
        return changed
    }

    /// Switches directly: the menu toggle, recognition turning off, or the screen locking. Returns the mode when it
    /// changed.
    @discardableResult
    public mutating func set(_ newMode: InteractionMode, because reason: ModeChangeReason = .menu) -> InteractionMode? {
        change(to: newMode, because: reason)
    }

    /// Hold progress (0...1) toward the mode the current one leads to, for the overlay: a fist everywhere but
    /// gesture mode, and the palm's hold toward desktop mode inside it.
    public func transitionProgress(at time: TimeInterval) -> Double {
        mode == .normal ? palm.holdProgress(at: time) : fist.holdProgress(at: time)
    }

    private mutating func change(to newMode: InteractionMode, because reason: ModeChangeReason) -> InteractionMode? {
        guard newMode != mode else { return nil }
        mode = newMode
        lastChangeReason = reason
        fist.reset()
        palm.reset()
        firstTap = nil
        handLostSince = nil
        sawHandInPointerMode = false
        wakingFistHeld = false
        return newMode
    }
}
