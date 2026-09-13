import Foundation

/// Decides when a held static pose fires: a few confirming frames, a hold that only advances
/// while the hand is still, then a cooldown and a required release before it can fire again.
/// Poses with `repeatSeconds` keep firing while held instead (e.g. stepping a value).
public struct GestureStateMachine: Sendable {
    public struct Timing: Codable, Equatable, Sendable {
        public var candidateFrames: Int
        public var holdSeconds: TimeInterval
        public var cooldownSeconds: TimeInterval
        public var repeatSeconds: TimeInterval?

        public init(candidateFrames: Int = 4, holdSeconds: TimeInterval = 0.4, cooldownSeconds: TimeInterval = 0.8, repeatSeconds: TimeInterval? = nil) {
            self.candidateFrames = candidateFrames
            self.holdSeconds = holdSeconds
            self.cooldownSeconds = cooldownSeconds
            self.repeatSeconds = repeatSeconds
        }
    }

    public enum Phase: Equatable, Sendable {
        case idle
        case candidate(frames: Int)
        case armed(since: TimeInterval)
        case repeating(nextFire: TimeInterval)
        case cooldown(until: TimeInterval, released: Bool)
        /// Cooldown is over but the pose never went away; it must be released first.
        case waitingForRelease
    }

    public var timing: Timing
    public private(set) var phase: Phase = .idle

    public init(timing: Timing = Timing()) {
        self.timing = timing
    }

    /// Hold progress in 0...1 for the overlay's progress bar.
    public func holdProgress(at time: TimeInterval) -> Double {
        guard case .armed(let since) = phase, timing.holdSeconds > 0 else { return 0 }
        return min(max((time - since) / timing.holdSeconds, 0), 1)
    }

    /// Feeds one frame. Returns true when the pose fires on this frame.
    public mutating func update(detected: Bool, handStill: Bool, at time: TimeInterval) -> Bool {
        switch phase {
        case .idle:
            if detected { phase = timing.candidateFrames <= 1 ? .armed(since: time) : .candidate(frames: 1) }
            return false

        case .candidate(let frames):
            guard detected else {
                phase = .idle
                return false
            }
            phase = frames + 1 >= timing.candidateFrames ? .armed(since: time) : .candidate(frames: frames + 1)
            return false

        case .armed(let since):
            guard detected else {
                phase = .idle
                return false
            }
            guard handStill else {
                phase = .armed(since: time)
                return false
            }
            guard time - since >= timing.holdSeconds else { return false }
            if let repeatSeconds = timing.repeatSeconds {
                phase = .repeating(nextFire: time + repeatSeconds)
            } else {
                phase = .cooldown(until: time + timing.cooldownSeconds, released: false)
            }
            return true

        case .repeating(let nextFire):
            guard detected else {
                phase = .idle
                return false
            }
            guard time >= nextFire, let repeatSeconds = timing.repeatSeconds else { return false }
            phase = .repeating(nextFire: time + repeatSeconds)
            return true

        case .cooldown(let until, let released):
            let releasedNow = released || !detected
            if time < until {
                phase = .cooldown(until: until, released: releasedNow)
            } else {
                phase = releasedNow && !detected ? .idle : (releasedNow ? .candidate(frames: 1) : .waitingForRelease)
            }
            return false

        case .waitingForRelease:
            if !detected { phase = .idle }
            return false
        }
    }

    public mutating func reset() {
        phase = .idle
    }
}
