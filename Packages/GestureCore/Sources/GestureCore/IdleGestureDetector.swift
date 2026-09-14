import Foundation

/// The gesture that parks recognition: close a fist and pull it back. It used to start with an open palm, which the
/// user dropped (2026-09-14).
///
/// Recorded (Tests/GestureCoreTests/Fixtures/sequences, `IDLE`, taken while the palm still came first): the fist is
/// held 0.4–0.5 s, and pulling back then shrinks it to 0.63–0.76 of that held size, with a misread frame on the way.
/// Closing a fist shrinks the hand's measured size all by itself (the middle knuckle moves with the fingers), and a fist
/// held to enter gesture mode starts the same way, so the fist is only compared with itself once it has settled, and
/// one small frame is noise rather than a pull back. Without the palm, anything that closes a fist starts one, so the
/// pull back has to come soon: a fist held past `maxHoldSeconds` must open before it can park.
public struct IdleGestureDetector: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// The fist's size is only compared with itself from this long after it closed: until then it is still closing.
        public var settleSeconds: TimeInterval = 0.2
        /// The fist must look pulled back for this many frames, dropouts aside...
        public var shrinkFrames = 2
        /// ...and for this long, so that a fist pushed toward the camera and pulled back — the play/pause pump — is
        /// not a park. A park keeps going back; a pump comes straight out again (2026-09-14).
        public var shrinkSeconds: TimeInterval = 0.25
        /// The pull back must come within this long of the fist closing.
        public var maxHoldSeconds: TimeInterval = 1.5
        /// Pulled back once the fist looks this much smaller than its largest size since it settled.
        public var shrinkRatio = 0.8
        /// The fist may drop out of tracking, or read as something else, this long without abandoning the gesture.
        public var dropoutTolerance: TimeInterval = 0.2

        public init() {}
    }

    public struct Sample: Sendable {
        public var fist: Bool
        /// Hand size in image heights.
        public var handScale: Double

        public init(fist: Bool, handScale: Double) {
            self.fist = fist
            self.handScale = handScale
        }
    }

    private struct Fold: Sendable {
        var start: TimeInterval
        var lastFist: TimeInterval
        /// Largest size seen since the fist settled; zero until then.
        var largest: Double
        var shrunkFrames = 0
        /// When the fist first looked pulled back, for `shrinkSeconds`.
        var shrinkingSince: TimeInterval?
    }

    public var settings: Settings
    private var fold: Fold?
    /// The fist in view has had its chance — it parked, or was held too long — and must open first.
    private var fistSpent = false

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Feeds one frame (nil when no hand was tracked). Returns true on the frame the pull back completes.
    public mutating func update(_ sample: Sample?, at time: TimeInterval) -> Bool {
        if let current = fold {
            if time - current.start > settings.maxHoldSeconds {
                fold = nil
                fistSpent = true
            } else if time - current.lastFist > settings.dropoutTolerance {
                fold = nil
            }
        }
        guard let sample else { return false }
        guard sample.fist else {
            // The hand opened. A fold under way rides out a misread frame, up to `dropoutTolerance`.
            fistSpent = false
            return false
        }
        guard var current = fold else {
            if !fistSpent {
                fold = Fold(start: time, lastFist: time, largest: 0)
            }
            return false
        }
        current.lastFist = time
        guard time - current.start >= settings.settleSeconds else {
            fold = current
            return false
        }
        if current.largest > 0, sample.handScale <= current.largest * settings.shrinkRatio {
            current.shrunkFrames += 1
            let since = current.shrinkingSince ?? time
            current.shrinkingSince = since
            if current.shrunkFrames >= settings.shrinkFrames, time - since >= settings.shrinkSeconds {
                fold = nil
                fistSpent = true
                return true
            }
        } else {
            current.shrunkFrames = 0
            current.shrinkingSince = nil
            current.largest = max(current.largest, sample.handScale)
        }
        fold = current
        return false
    }

    public mutating func reset() {
        fold = nil
        fistSpent = false
    }

    /// The fist in view was used for something else — the play/pause pump — so it must open before it can park.
    /// Without this, the hand relaxing after a pump reads as the pull back.
    public mutating func spendCurrentFist() {
        fold = nil
        fistSpent = true
    }
}
