import Foundation

/// Locks the screen the moment a face nobody enrolled turns up after an empty room (the user's call, 2026-09-16).
///
/// Vetting starts only after a stretch with nobody there, so whoever was already sitting at the Mac is never put
/// through it, and it gives up after a while: a face that never got a clear look is not a stranger. Only a face big
/// enough to judge, seen several checks in a row and matching nobody, locks; any enrolled face ends the vetting, and
/// so does the person leaving again — the empty screen's own timer takes over then.
public struct StrangerWatch: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Nobody for this long, then somebody: that somebody gets checked.
        public var absenceBefore: TimeInterval = 3
        /// Vetting gives up this long after they turned up.
        public var window: TimeInterval = 10
        /// Checks in a row that see a face and match nobody.
        public var strangerChecks = 4
        /// At or above this a face is someone enrolled: the bar the lock's own check uses.
        public var ownerThreshold = FaceVerification.Settings().threshold
        /// A face smaller than this share of the image height is too far away to judge.
        public var minFaceHeight = 0.08

        public init() {}
    }

    public var settings: Settings
    private var lastPresent: TimeInterval?
    private var awaitingReturn = false
    private var vettingSince: TimeInterval?
    private var strangerChecks = 0

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Someone turned up after an empty room and hasn't been placed yet: their face is worth checking.
    public var isVetting: Bool { vettingSince != nil }

    /// Feeds one frame's presence.
    public mutating func update(personPresent: Bool, at time: TimeInterval) {
        defer { if personPresent { lastPresent = time } }
        guard personPresent else {
            // They left: the empty screen's own timer takes it from here, and coming back starts vetting again.
            vettingSince = nil
            strangerChecks = 0
            if time - (lastPresent ?? -.infinity) >= settings.absenceBefore {
                awaitingReturn = true
            }
            return
        }
        if awaitingReturn {
            awaitingReturn = false
            vettingSince = time
            strangerChecks = 0
        }
        if let since = vettingSince, time - since > settings.window {
            vettingSince = nil
            strangerChecks = 0
        }
    }

    /// Feeds one face check. True when the face belongs to nobody enrolled and the screen should lock now.
    public mutating func faceChecked(similarity: Double?, faceHeight: Double, at time: TimeInterval) -> Bool {
        guard let since = vettingSince else { return false }
        guard time - since <= settings.window else {
            vettingSince = nil
            strangerChecks = 0
            return false
        }
        // No face, or too far away to judge: nothing either way.
        guard let similarity, faceHeight >= settings.minFaceHeight else { return false }
        guard similarity < settings.ownerThreshold else {
            // Somebody enrolled: leave them be.
            vettingSince = nil
            strangerChecks = 0
            return false
        }
        strangerChecks += 1
        guard strangerChecks >= settings.strangerChecks else { return false }
        vettingSince = nil
        strangerChecks = 0
        return true
    }

    /// After locking or unlocking: whoever is there now has been placed.
    public mutating func reset() {
        lastPresent = nil
        awaitingReturn = false
        vettingSince = nil
        strangerChecks = 0
    }
}
