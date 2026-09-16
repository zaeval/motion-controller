import Foundation

/// Locks the screen as soon as a face nobody enrolled is recognized, without waiting out the empty-room timer (the
/// user's call, 2026-09-16). Every face the camera sees while the screen is on is checked, not only the ones that
/// turn up after an empty seat: somebody taking the chair a second after the owner left counts too.
///
/// Only a face big enough to judge, seen several checks in a row and matching nobody, locks. Any enrolled face
/// starts the count over, and a face the camera can't make out is no evidence either way. Touch ID or the password
/// buys `quietAfterUnlock` of peace, because whoever got in that way proved who they are, and re-locking them every
/// couple of seconds is what a camera that can't recognize them would otherwise do.
public struct StrangerWatch: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
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
    private var strangerChecks = 0
    private var quietUntil: TimeInterval?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// How many checks in a row have seen a face belonging to nobody, for the log.
    public var checksAgainst: Int { strangerChecks }

    /// Whether face checks can lock right now, or are only being kept warm.
    public func isQuiet(at time: TimeInterval) -> Bool { time < (quietUntil ?? -.infinity) }

    /// Feeds one face check. True when the face belongs to nobody enrolled and the screen should lock now.
    public mutating func faceChecked(similarity: Double?, faceHeight: Double, at time: TimeInterval) -> Bool {
        // No face, or too far away to judge: nothing either way, and the count stands.
        guard let similarity, faceHeight >= settings.minFaceHeight else { return false }
        guard similarity < settings.ownerThreshold else {
            // Somebody enrolled is in view: nothing here is a stranger.
            strangerChecks = 0
            quietUntil = nil
            return false
        }
        // Quiet after Touch ID: keep checking, in case somebody enrolled turns up and ends it early, but count nothing
        // against anyone. Once the quiet is over, a stranger has to make the whole count again.
        guard !isQuiet(at: time) else {
            strangerChecks = 0
            return false
        }
        strangerChecks += 1
        guard strangerChecks >= settings.strangerChecks else { return false }
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
        strangerChecks = 0
        quietUntil = nil
    }
}
