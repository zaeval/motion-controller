import Foundation

/// Which button a finger tap clicks.
public enum FingerTap: String, Codable, Sendable {
    /// The index dipped with the middle finger folded (☝️).
    case left
    /// The index dipped while the middle finger stayed up (✌️).
    case right
}

/// Index-finger taps: the finger bends down and straightens again, like tapping a trackpad in the air.
///
/// Recorded taps (Tests/GestureCoreTests/Fixtures/sequences, `left-click` and `right-click`) last one or two frames at
/// 20 fps, often blur a joint or the whole hand out of tracking for a frame, and shorten the index anywhere from a
/// quarter to two thirds of its resting reach. So a dip is judged against the finger's own recent resting reach
/// rather than a pose, tracking gaps inside a dip are bridged, and at least one frame must actually measure the dip:
/// dropouts alone never tap. When the middle finger was up and dips too, it is a two-finger flick, never a tap; a
/// right click needs the middle finger actually seen up. A pinch owns its own click, and a slow fold, a moving palm,
/// or fingers blurred short by a swipe that just passed are not taps either, and neither is a dip from a hand that
/// hasn't rested long enough to show how far its index reaches.
public struct TapDetector: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// The index dips once its reach falls below this fraction of its resting reach...
        public var dipFraction = 0.72
        /// ...and the tap completes when it is back above this fraction.
        public var recoverFraction = 0.85
        /// A finger resting shorter than this (hand sizes) is folded and can't tap.
        public var minRestingReach = 0.6
        /// A dip needs this many resting frames before it. A hand just in view, or just out of a fist, measured a
        /// fist frame and one pointing frame and then "tapped" on its first dropout.
        public var minRestSamples = 4
        /// Longer than this is bending or folding the finger, not tapping: the dip ends and the finger rests there.
        public var maxDipSeconds: TimeInterval = 0.45
        /// Tracking gaps up to this long inside a dip don't end it.
        public var dropoutTolerance: TimeInterval = 0.2
        /// A middle finger that was up must stay above this fraction of its resting reach, or the dip was a flick.
        public var companionHoldFraction = 0.8
        /// How long resting reach is remembered.
        public var restWindow: TimeInterval = 0.6
        /// The palm may travel at most this far during a tap, in hand sizes: a moving hand blurs fingers short.
        public var maxPalmTravel = 0.4
        /// No dip starts within `sweepCooldown` of the palm moving faster than this (image heights per second), and a
        /// dip it moves that fast during isn't a tap. A recorded swipe blurred the index short right after the palm
        /// swept at 1.9–2.7, and a fast cursor move blurred it short while sweeping at 1.4–1.6; taps jerk the palm to ~1.
        public var sweepSpeed = 1.5
        public var sweepCooldown: TimeInterval = 0.3

        public init() {}
    }

    public struct Sample: Sendable {
        /// Index tip → index knuckle in hand sizes; nil when either joint wasn't confidently tracked.
        public var indexReach: Double?
        public var middleReach: Double?
        public var middleExtended: Bool?
        public var pinching: Bool
        /// Palm anchor in image heights.
        public var palm: Vec2
        /// Hand size in image heights.
        public var handScale: Double
        /// Palm speed in image heights per second.
        public var palmSpeed: Double

        public init(
            indexReach: Double?, middleReach: Double?, middleExtended: Bool?, pinching: Bool, palm: Vec2,
            handScale: Double, palmSpeed: Double = 0
        ) {
            self.indexReach = indexReach
            self.middleReach = middleReach
            self.middleExtended = middleExtended
            self.pinching = pinching
            self.palm = palm
            self.handScale = handScale
            self.palmSpeed = palmSpeed
        }
    }

    private struct Rest: Sendable {
        var time: TimeInterval
        var index: Double
        var middle: Double?
        var middleExtended: Bool?
    }

    private struct Dip: Sendable {
        var start: TimeInterval
        var lastSeen: TimeInterval
        var palmStart: Vec2
        var restingIndex: Double
        var middleUp: Bool
        var restingMiddle: Double?
        var middleSeenUp = false
        var disqualified = false
    }

    public var settings: Settings
    private var rest: [Rest] = []
    private var dip: Dip?
    private var lastSweep: TimeInterval = -.infinity

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// The index is mid-dip; a cursor should hold still until it is back up.
    public var isDipping: Bool { dip != nil }

    /// Feeds one frame (nil when no hand was tracked). Returns the tap that completed on this frame, if any.
    public mutating func update(_ sample: Sample?, at time: TimeInterval) -> FingerTap? {
        rest.removeAll { time - $0.time > settings.restWindow }
        if let current = dip, time - current.lastSeen > settings.dropoutTolerance {
            dip = nil
        }
        guard let sample else { return nil }
        let recentlySwept = time - lastSweep <= settings.sweepCooldown
        if sample.palmSpeed > settings.sweepSpeed { lastSweep = time }
        // A blurred-out index bridges a dip but never measures one.
        guard let reach = sample.indexReach else { return nil }

        if var current = dip {
            current.lastSeen = time
            judge(&current, sample, at: time)
            if time - current.start > settings.maxDipSeconds {
                // Held down this long the finger is bending, not tapping; where it rests now is its new rest.
                dip = nil
                rest.removeAll()
                return nil
            }
            guard reach >= current.restingIndex * settings.recoverFraction else {
                dip = current
                return nil
            }
            dip = nil
            remember(sample, reach, at: time)
            guard !current.disqualified else { return nil }
            guard current.middleUp else { return .left }
            return current.middleSeenUp ? .right : nil
        }

        guard !recentlySwept, rest.count >= settings.minRestSamples,
              let restingIndex = Self.median(rest.map(\.index)),
              restingIndex >= settings.minRestingReach,
              reach < restingIndex * settings.dipFraction
        else {
            // Only straight-finger frames define resting reach; the band between dip and recovery counts for neither.
            if reach >= (Self.median(rest.map(\.index)) ?? 0) * settings.recoverFraction {
                remember(sample, reach, at: time)
            }
            return nil
        }

        let votes = rest.compactMap(\.middleExtended)
        var started = Dip(
            start: time,
            lastSeen: time,
            palmStart: sample.palm,
            restingIndex: restingIndex,
            middleUp: votes.filter { $0 }.count * 2 > votes.count,
            restingMiddle: Self.median(rest.compactMap(\.middle))
        )
        judge(&started, sample, at: time)
        dip = started
        return nil
    }

    public mutating func reset() {
        rest.removeAll()
        dip = nil
        lastSweep = -.infinity
    }

    private func judge(_ dip: inout Dip, _ sample: Sample, at time: TimeInterval) {
        let travel = sample.palm.distance(to: dip.palmStart) / max(sample.handScale, 1e-6)
        if sample.pinching || travel > settings.maxPalmTravel || sample.palmSpeed > settings.sweepSpeed {
            dip.disqualified = true
        }
        guard dip.middleUp, let middle = sample.middleReach, let restingMiddle = dip.restingMiddle else { return }
        if middle < restingMiddle * settings.companionHoldFraction {
            dip.disqualified = true
        } else {
            dip.middleSeenUp = true
        }
    }

    private mutating func remember(_ sample: Sample, _ reach: Double, at time: TimeInterval) {
        rest.append(Rest(time: time, index: reach, middle: sample.middleReach, middleExtended: sample.middleExtended))
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.sorted()[values.count / 2]
    }
}
