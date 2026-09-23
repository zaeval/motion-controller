import Foundation

/// Locks the screen as soon as a face nobody enrolled is seen at the unlocked Mac while nobody enrolled is (the user's
/// call, 2026-09-23). It used to check only whoever turned up after the seat had emptied, which let a stranger who
/// stepped up beside the owner, and stayed once the owner turned away, go unchecked.
///
/// Faces are checked the whole time anyone is in view. A face counts against whoever is there only when it is big
/// enough to judge, scores clearly below the enrolled bar — `strangerBelow` leaves a band where a badly lit owner
/// lands, which on the bot Mac's camera is 0.41–0.45 — and no enrolled face has been seen for `ownerRecency`: an owner
/// at the screen vouches for whoever is behind them, and one who looks away for a moment is still there. That also
/// keeps the owner's own face unlock from being followed straight by a re-lock with somebody else still in view.
/// `strangerChecks` of those within `window` lock; a face the camera can't make out is no evidence either way.
///
/// Touch ID or the password buys `quietAfterUnlock` of peace, because whoever got in that way proved who they are, and
/// re-locking them every couple of seconds is what a camera that can't recognize them would otherwise do. An enrolled
/// face ends it early.
public struct StrangerWatch: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Faces matching nobody that lock, a quarter second apart at the face checks' rate...
        public var strangerChecks = 5
        /// ...all within this long.
        public var window: TimeInterval = 5
        /// At or above this a face is someone enrolled: the bar the lock's own check uses.
        public var ownerThreshold = FaceVerification.Settings().threshold
        /// Below this a face is somebody else. Between the two it could be either, and counts for nothing.
        public var strangerBelow = 0.40
        /// An enrolled face seen this recently means its owner is still there.
        public var ownerRecency: TimeInterval = 3
        /// A face smaller than this share of the image height is too far away to judge.
        public var minFaceHeight = 0.08
        /// No locking on faces for this long after Touch ID or the password let someone in.
        public var quietAfterUnlock: TimeInterval = 120

        public init() {}
    }

    public var settings: Settings
    /// When the faces now counting against whoever is there were seen.
    private var strangerTimes: [TimeInterval] = []
    private var ownerSeen: TimeInterval?
    private var quietUntil: TimeInterval?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// How many faces matching nobody are counting toward a lock, for the log.
    public var checksAgainst: Int { strangerTimes.count }
    /// Whether a face could lock right now, or the last way in was Touch ID and everyone is being left alone.
    public func isQuiet(at time: TimeInterval) -> Bool { time < (quietUntil ?? -.infinity) }
    /// Somebody enrolled was seen within `ownerRecency`, and is vouching for everyone else in view.
    public func ownerIsThere(at time: TimeInterval) -> Bool {
        time - (ownerSeen ?? -.infinity) < settings.ownerRecency
    }

    /// Feeds one face check: the best match among the faces in view (nil when there were none) and that face's
    /// height. True when it belongs to nobody enrolled and the screen should lock now.
    public mutating func faceChecked(similarity: Double?, faceHeight: Double, at time: TimeInterval) -> Bool {
        strangerTimes.removeAll { time - $0 > settings.window }
        // No face, or too far away to judge: nothing either way, and the count stands.
        guard let similarity, faceHeight >= settings.minFaceHeight else { return false }
        guard similarity < settings.ownerThreshold else {
            ownerSeen = time
            strangerTimes = []
            quietUntil = nil
            return false
        }
        guard similarity < settings.strangerBelow else { return false }
        // Quiet after Touch ID: count nothing against anyone, and once it is over a stranger makes the whole count.
        guard !isQuiet(at: time) else {
            strangerTimes = []
            return false
        }
        guard !ownerIsThere(at: time) else { return false }
        strangerTimes.append(time)
        guard strangerTimes.count >= settings.strangerChecks else { return false }
        strangerTimes = []
        return true
    }

    /// The owner's face just unlocked the screen: they are there, vouching for whoever came with them.
    public mutating func sawOwner(at time: TimeInterval) {
        ownerSeen = time
        strangerTimes = []
    }

    /// Touch ID or the password got someone in: their face is not going to be recognized either, so leave them alone
    /// for a while.
    public mutating func quiet(from time: TimeInterval) {
        strangerTimes = []
        quietUntil = time + settings.quietAfterUnlock
    }

    public mutating func reset() {
        strangerTimes = []
        ownerSeen = nil
        quietUntil = nil
    }
}
