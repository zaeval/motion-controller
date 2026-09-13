import Foundation

/// The gesture that parks recognition: show an open palm, fold it into a fist, and pull the fist back.
///
/// Recorded (Tests/GestureCoreTests/Fixtures/sequences, `IDLE`): the palm is shown for 0.6–0.9 s, the fold takes a
/// frame or two, the fist is held 0.4–0.5 s, and pulling back then shrinks it to 0.63–0.76 of that held size.
/// Closing a fist shrinks the hand's measured size all by itself (the middle knuckle moves with the fingers), and a
/// fist held to enter gesture mode starts the same way, so the fist is only compared with itself once it has settled,
/// a glimpse of an open palm doesn't count as showing one, and one small frame is noise rather than a pull back.
public struct IdleGestureDetector: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// The open palm counts as shown once it has been held this long, over this many frames.
        public var minPalmSeconds: TimeInterval = 0.2
        public var minPalmFrames = 4
        /// The fist must close within this long of a shown open palm.
        public var foldWindow: TimeInterval = 0.5
        /// The fist's size is only compared with itself from this long after it closed: until then it is still closing.
        public var settleSeconds: TimeInterval = 0.2
        /// The fist must look pulled back for this many frames, dropouts aside.
        public var shrinkFrames = 2
        /// The pull back must come within this long of the fold.
        public var maxHoldSeconds: TimeInterval = 1.5
        /// Pulled back once the fist looks this much smaller than its largest size since the fold.
        public var shrinkRatio = 0.8
        /// The fist may drop out of tracking this long without abandoning the gesture.
        public var dropoutTolerance: TimeInterval = 0.2

        public init() {}
    }

    public struct Sample: Sendable {
        public var openPalm: Bool
        public var fist: Bool
        /// Hand size in image heights.
        public var handScale: Double

        public init(openPalm: Bool, fist: Bool, handScale: Double) {
            self.openPalm = openPalm
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
    }

    public var settings: Settings
    private var lastOpenPalm: TimeInterval?
    private var palmSince: TimeInterval?
    private var palmFrames = 0
    private var fold: Fold?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Feeds one frame (nil when no hand was tracked). Returns true on the frame the pull back completes.
    public mutating func update(_ sample: Sample?, at time: TimeInterval) -> Bool {
        if let current = fold,
           time - current.lastFist > settings.dropoutTolerance || time - current.start > settings.maxHoldSeconds {
            fold = nil
        }
        guard let sample else { return false }
        if sample.openPalm {
            palmSince = palmSince ?? time
            palmFrames += 1
            if palmFrames >= settings.minPalmFrames, time - (palmSince ?? time) >= settings.minPalmSeconds {
                lastOpenPalm = time
            }
            fold = nil
            return false
        }
        guard sample.fist else {
            // Anything else breaks the palm's hold, but a fold already under way rides it out.
            palmSince = nil
            palmFrames = 0
            return false
        }
        palmSince = nil
        palmFrames = 0
        guard var current = fold else {
            if let open = lastOpenPalm, time - open <= settings.foldWindow {
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
            if current.shrunkFrames >= settings.shrinkFrames {
                reset()
                return true
            }
        } else {
            current.shrunkFrames = 0
            current.largest = max(current.largest, sample.handScale)
        }
        fold = current
        return false
    }

    public mutating func reset() {
        lastOpenPalm = nil
        palmSince = nil
        palmFrames = 0
        fold = nil
    }
}
