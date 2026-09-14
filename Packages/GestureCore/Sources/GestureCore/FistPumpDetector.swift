import Foundation

/// ✊ pushed toward the camera and back, twice, quickly — the user's "팡팡" (2026-09-14). It plays and pauses.
///
/// It was a palm being pumped until the same day: showing a palm is how desktop mode is asked for now, so the palm
/// was doing two jobs and the pump lost. A fist has nothing else to do in gesture mode (the fist that opens gesture
/// mode is only read outside it).
///
/// What it watches is the hand's apparent size, since a hand moving toward the camera grows. That measure is noisy —
/// the wrist-to-knuckle distance jumps about a third between frames in fast motion — so a peak has to hold for
/// `peakFrames` in a row, and the baseline is the smallest hand seen recently rather than any single frame.
///
/// Two things it must never be. A park is ✊ pulled back, which is a fist shrinking — the same shape, the other way
/// round — so `IdleGestureDetector` waits for the pulled-back fist to *stay* back before parking, and a pump pushes
/// out first. Opening the hand cancels. And a swipe travels sideways, so the hand has to stay within `stillRadius`
/// of where it started throughout.
///
/// Measured against the user's own three "palm-pang-pang" recordings (2026-09-14) — of the palm version of the
/// gesture, so the numbers came from a palm and the shape has since changed to a fist. They are all relative to the
/// hand's own size, so they should carry over; a fist recording would settle it.
/// - **It fires on the second push out, not on a second return.** Their hand goes out, back, out — and then stays
///   out. Waiting for the second return meant waiting for something they don't do.
/// - Pushes measure +0.19…+0.40 over the rolling baseline, so the rise mark sits at 0.15, and the two pushes are
///   about 0.27 s apart.
/// - **The return between pushes is measured against the peak, not the baseline.** In the take where they raised the
///   hand into frame and pumped it there, the baseline kept the small far-away hand for a while, so the dip between
///   two pushes still read +0.22 over it — a fixed return mark can't see that dip at all, while "came back 40% of
///   the way down from the peak" sees it in every take.
/// - A frame or two in the middle doesn't read as an open palm even with the palm held flat at the camera, so
///   `poseGrace` skips those frames instead of throwing the pumps away.
public struct FistPumpDetector: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// How much bigger than the baseline the hand has to get to count as pushed out.
        public var riseFraction = 0.15
        /// It has to come back down this much of the way from the peak toward the baseline before the next push
        /// counts. Peak-relative, so a baseline that is still catching up doesn't hide the dip.
        public var returnDrop = 0.4
        /// Frames in a row at the peak, so one mistracked frame isn't a pump.
        public var peakFrames = 2
        /// Both pushes have to land within this long of the first one starting.
        public var window: TimeInterval = 1.2
        /// How far the palm may wander during the pumps, in image heights: a sweep isn't a pump.
        public var stillRadius = 0.08
        /// The baseline is the smallest hand seen over this long.
        public var baselineWindow: TimeInterval = 1.5
        /// Nothing fires again this soon.
        public var cooldown: TimeInterval = 1.0
        /// Frames that don't read as a fist are skipped for this long before the pumps are thrown away.
        public var poseGrace: TimeInterval = 0.3

        public init() {}
    }

    public struct Sample: Sendable {
        /// Hand size in image heights (wrist to middle knuckle).
        public var handScale: Double
        /// Palm anchor in image-height units.
        public var anchor: Vec2
        /// The hand is closed into a fist.
        public var fist: Bool
        /// The hand is open: the cancel.
        public var openHand: Bool

        public init(handScale: Double, anchor: Vec2, fist: Bool, openHand: Bool = false) {
            self.handScale = handScale
            self.anchor = anchor
            self.fist = fist
            self.openHand = openHand
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
    /// Pushed out and waiting to come back: the biggest hand of this push, and the baseline it rose from.
    private var out: (peak: Double, base: Double)?
    private var lastFire = -TimeInterval.infinity
    /// The last frame that read as a fist, for `poseGrace`.
    private var lastFist: TimeInterval?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// How far along a pump the user is (0, 0.5, 1), for the overlay.
    public var progress: Double { min(Double(pumps) / 2, 1) }

    /// Feeds one frame (nil when no hand was seen). True on the frame the second push out lands.
    public mutating func update(_ sample: Sample?, at time: TimeInterval) -> Bool {
        guard let sample, !sample.openHand else {
            // Opening the hand is the cancel, and a hand that went missing was doing something else.
            reset()
            return false
        }
        guard sample.fist else {
            // A hand mid-pump drops out of the fist pose for a frame here and there, so a short gap is skipped
            // rather than counted against the user.
            if let lastFist, time - lastFist > settings.poseGrace { reset() }
            return false
        }
        lastFist = time
        recent.append((time, sample.handScale))
        recent.removeAll { time - $0.time > settings.baselineWindow }
        guard let baseline = recent.map(\.scale).min(), baseline > 0 else { return false }

        // Counting from the first push, not from the first frame: a palm resting in view doesn't start the clock.
        if let origin {
            if time - origin.time > settings.window || sample.anchor.distance(to: origin.anchor) > settings.stillRadius {
                self.origin = nil
                pumps = 0
                peakRun = 0
                out = nil
            }
        }

        // Out already: wait for the hand to come back down, tracking how far out this push went.
        if var current = out {
            current.peak = max(current.peak, sample.handScale)
            if sample.handScale <= current.peak - settings.returnDrop * (current.peak - current.base) {
                self.out = nil
                peakRun = 0
            } else {
                self.out = current
            }
            return false
        }
        guard sample.handScale >= baseline * (1 + settings.riseFraction) else {
            peakRun = 0
            return false
        }
        peakRun += 1
        guard peakRun >= settings.peakFrames else { return false }
        out = (peak: sample.handScale, base: baseline)
        peakRun = 0
        if origin == nil { origin = (sample.anchor, time) }
        pumps += 1
        // The second push is the second 팡: firing here rather than on its return is what their recordings needed,
        // because the hand stays out afterwards.
        guard pumps >= 2, time - lastFire >= settings.cooldown else { return false }
        lastFire = time
        reset()
        return true
    }

    public mutating func reset() {
        recent.removeAll()
        origin = nil
        pumps = 0
        peakRun = 0
        out = nil
        lastFist = nil
    }
}
