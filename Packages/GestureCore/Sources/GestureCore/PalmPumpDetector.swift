import Foundation

/// 🖐 pushed toward the camera and back, twice, quickly — the user's "팡팡" (2026-09-14). It plays and pauses.
///
/// Holding the palm out used to do it, and that is the same thing a swipe starts from: the user had to wait with
/// their hand still, which is exactly the swipe's arming pose, and the wait now opens desktop mode instead. A pump
/// has no still pose to collide with.
///
/// What it watches is the hand's apparent size, since a hand moving toward the camera grows. That measure is noisy —
/// the wrist-to-knuckle distance jumps about a third between frames in fast motion — so a peak has to hold for
/// `peakFrames` in a row, and the baseline is the smallest hand seen recently rather than any single frame.
///
/// Two things it must never be. A park is ✊ pulled back, whose second half is a hand shrinking, so a pump only
/// counts when the hand goes *out* first and comes back while still an open palm; closing it cancels. And a swipe
/// travels sideways, sometimes leaning in as it lifts, so the palm has to stay within `stillRadius` of where it
/// started throughout.
public struct PalmPumpDetector: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// How much bigger than the baseline the hand has to get to count as pushed out.
        public var riseFraction = 0.15
        /// It has to come back under this much of the baseline before the next push counts.
        public var returnFraction = 0.06
        /// Frames in a row at the peak, so one mistracked frame isn't a pump.
        public var peakFrames = 2
        /// Both pushes have to land within this long of the first one starting.
        public var window: TimeInterval = 1.5
        /// How far the palm may wander during the pumps, in image heights: a sweep isn't a pump.
        public var stillRadius = 0.08
        /// The baseline is the smallest hand seen over this long.
        public var baselineWindow: TimeInterval = 1.5
        /// Nothing fires again this soon.
        public var cooldown: TimeInterval = 1.0

        public init() {}
    }

    public struct Sample: Sendable {
        /// Hand size in image heights (wrist to middle knuckle).
        public var handScale: Double
        /// Palm anchor in image-height units.
        public var anchor: Vec2
        /// The pose is an open palm facing the camera.
        public var openPalm: Bool
        public var fist: Bool

        public init(handScale: Double, anchor: Vec2, openPalm: Bool, fist: Bool = false) {
            self.handScale = handScale
            self.anchor = anchor
            self.openPalm = openPalm
            self.fist = fist
        }
    }

    public var settings: Settings
    /// Hand sizes seen recently, for the baseline.
    private var recent: [(time: TimeInterval, scale: Double)] = []
    /// Where the palm was when the first push began, and when that was.
    private var origin: (anchor: Vec2, time: TimeInterval)?
    private var pumps = 0
    /// Frames in a row the hand has been out past the rise.
    private var peakRun = 0
    /// Out past the rise now, waiting to come back.
    private var isOut = false
    private var lastFire = -TimeInterval.infinity

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// How far along a pump the user is (0, 0.5, 1), for the overlay.
    public var progress: Double { min(Double(pumps) / 2, 1) }

    /// Feeds one frame (nil when no hand was seen). True on the frame the second pump lands.
    public mutating func update(_ sample: Sample?, at time: TimeInterval) -> Bool {
        guard let sample, sample.openPalm, !sample.fist else {
            // An open palm is the whole gesture: a hand that closes or goes missing was doing something else.
            reset()
            return false
        }
        recent.append((time, sample.handScale))
        recent.removeAll { time - $0.time > settings.baselineWindow }
        guard let baseline = recent.map(\.scale).min(), baseline > 0 else { return false }

        // Counting from the first push, not from the first frame: a palm resting in view doesn't start the clock.
        if let origin {
            if time - origin.time > settings.window || sample.anchor.distance(to: origin.anchor) > settings.stillRadius {
                self.origin = nil
                pumps = 0
                peakRun = 0
                isOut = false
            }
        }

        let out = sample.handScale >= baseline * (1 + settings.riseFraction)
        let back = sample.handScale <= baseline * (1 + settings.returnFraction)
        if out {
            peakRun += 1
            if peakRun >= settings.peakFrames, !isOut {
                isOut = true
                if origin == nil { origin = (sample.anchor, time) }
            }
        } else {
            peakRun = 0
            if isOut, back {
                isOut = false
                pumps += 1
                guard pumps >= 2, time - lastFire >= settings.cooldown else { return false }
                lastFire = time
                reset()
                return true
            }
        }
        return false
    }

    public mutating func reset() {
        recent.removeAll()
        origin = nil
        pumps = 0
        peakRun = 0
        isOut = false
    }
}
