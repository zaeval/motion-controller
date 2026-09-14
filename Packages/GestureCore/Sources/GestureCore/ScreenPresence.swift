import Foundation

/// Whether the screen should stay awake or dim, from who is in front of the camera. Pure, so its timing can be tested
/// without a display.
public struct ScreenPresence: Sendable {
    public enum State: String, Codable, Sendable {
        /// Someone is there, or left too recently to be sure: the screen shows.
        case awake
        /// Nobody has been there for `dimAfter`: the screen goes black. It never sleeps either way.
        case dimmed
    }

    public struct Settings: Codable, Equatable, Sendable {
        /// Counted from the last frame anyone was seen, the clock `ModeController` parks recognition on. The user's
        /// call (2026-09-14): recognition parks after 5 s, and the screen goes dark after 10.
        public var dimAfter: TimeInterval = 10

        public init() {}
    }

    public var settings: Settings
    /// Nil until the first frame.
    public private(set) var state: State?
    private var firstFrame: TimeInterval?
    private var lastPersonSeen: TimeInterval?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Feeds one frame. Returns the new state on the first frame and on every frame it changes.
    public mutating func update(personPresent: Bool, at time: TimeInterval) -> State? {
        let start = firstFrame ?? time
        firstFrame = start
        if personPresent { lastPersonSeen = time }
        let next: State = time - (lastPersonSeen ?? start) >= settings.dimAfter ? .dimmed : .awake
        guard next != state else { return nil }
        state = next
        return next
    }

    /// The screen was let back on without anyone being seen: the owner unlocked it, or the lock was switched off.
    /// Awake now, with the absence clock starting over, so it doesn't go straight back to dark.
    public mutating func unlock(at time: TimeInterval) -> State? {
        firstFrame = firstFrame ?? time
        lastPersonSeen = time
        guard state != .awake else { return nil }
        state = .awake
        return .awake
    }
}
