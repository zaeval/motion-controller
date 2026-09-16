import Foundation

/// Locks the screen as soon as a face nobody enrolled is recognized, without waiting out the empty-room timer (the
/// user's call, 2026-09-16).
///
/// Faces are only checked when somebody turns up after the seat was empty, not the whole time anyone is there: every
/// check costs about a quarter of the frame rate hand tracking runs at, and whoever is already sitting at the Mac has
/// been placed (the user's call, 2026-09-16). Body tracking blinks out for a second at a time on a person sitting
/// still, and a blink used to end the checking for good, so only an absence past `absenceTolerance` ends it.
///
/// Only a face big enough to judge, seen several checks in a row and matching nobody, locks. Any enrolled face ends
/// the checking, and a face the camera can't make out is no evidence either way. Touch ID or the password buys
/// `quietAfterUnlock` of peace, because whoever got in that way proved who they are, and re-locking them every couple
/// of seconds is what a camera that can't recognize them would otherwise do.
public struct StrangerWatch: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Nobody for this long, then somebody: that somebody gets checked. As short as the flicker tolerance on
        /// purpose, so anyone who turns up while the screen is counting down to going dark is checked — the ten
        /// seconds of that countdown is exactly when somebody else can take the seat (the user's call, 2026-09-16).
        public var absenceBefore: TimeInterval = 2
        /// Tracking blinking out for less than this doesn't end the checking.
        public var absenceTolerance: TimeInterval = 2
        /// Checking gives up this long after they turned up: a face that never got a clear look isn't a stranger.
        public var window: TimeInterval = 10
        /// Checks in a row that see a clear face and match nobody.
        public var strangerChecks = 5
        /// At or above this a face is someone enrolled: the bar the lock's own check uses.
        public var ownerThreshold = FaceVerification.Settings().threshold
        /// A face smaller than this share of the image height is too far away to judge.
        public var minFaceHeight = 0.08
        /// No locking on faces for this long after Touch ID or the password let someone in.
        public var quietAfterUnlock: TimeInterval = 120

        public init() {}
    }

    public var settings: Settings
    private var lastPresent: TimeInterval?
    private var awaitingReturn = false
    private var checkingSince: TimeInterval?
    private var strangerChecks = 0
    private var quietUntil: TimeInterval?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Somebody turned up after an empty seat and hasn't been placed yet: their face is worth checking.
    public var isChecking: Bool { checkingSince != nil }
    /// How many checks in a row have seen a face belonging to nobody, for the log.
    public var checksAgainst: Int { strangerChecks }
    /// Whether a face could lock right now, or the last way in was Touch ID and everyone is being left alone.
    public func isQuiet(at time: TimeInterval) -> Bool { time < (quietUntil ?? -.infinity) }

    /// Feeds one frame's presence.
    public mutating func update(personPresent: Bool, at time: TimeInterval) {
        defer { if personPresent { lastPresent = time } }
        guard personPresent else {
            let away = time - (lastPresent ?? -.infinity)
            // They left: the empty screen's own timer takes it from here, and coming back starts the checking.
            if away >= settings.absenceTolerance {
                checkingSince = nil
                strangerChecks = 0
            }
            if away >= settings.absenceBefore {
                awaitingReturn = true
            }
            return
        }
        if awaitingReturn {
            awaitingReturn = false
            checkingSince = time
            strangerChecks = 0
        }
        if let since = checkingSince, time - since > settings.window {
            checkingSince = nil
            strangerChecks = 0
        }
    }

    /// Feeds one face check. True when the face belongs to nobody enrolled and the screen should lock now.
    public mutating func faceChecked(similarity: Double?, faceHeight: Double, at time: TimeInterval) -> Bool {
        guard let since = checkingSince else { return false }
        guard time - since <= settings.window else {
            checkingSince = nil
            strangerChecks = 0
            return false
        }
        // No face, or too far away to judge: nothing either way, and the count stands.
        guard let similarity, faceHeight >= settings.minFaceHeight else { return false }
        guard similarity < settings.ownerThreshold else {
            // Somebody enrolled: leave them be, and stop checking until the seat empties again.
            checkingSince = nil
            strangerChecks = 0
            quietUntil = nil
            return false
        }
        // Quiet after Touch ID: keep looking, in case somebody enrolled turns up and ends it early, but count nothing
        // against anyone. Once the quiet is over, a stranger has to make the whole count again.
        guard !isQuiet(at: time) else {
            strangerChecks = 0
            return false
        }
        strangerChecks += 1
        guard strangerChecks >= settings.strangerChecks else { return false }
        checkingSince = nil
        strangerChecks = 0
        return true
    }

    /// Touch ID or the password got someone in: their face is not going to be recognized either, so leave them alone
    /// for a while.
    public mutating func quiet(from time: TimeInterval) {
        strangerChecks = 0
        quietUntil = time + settings.quietAfterUnlock
    }

    public mutating func reset() {
        lastPresent = nil
        awaitingReturn = false
        checkingSince = nil
        strangerChecks = 0
        quietUntil = nil
    }
}
