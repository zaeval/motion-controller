import Foundation

/// Stands in for the frames Vision loses the hand in.
///
/// With a small hand that is 35–40% of them (measured 2026-09-15: a pointing hand at 0.15 of the frame's height,
/// against none at all for a palm at 0.26), and cropping around the hand to help it turned out to be a dead end.
/// A frame with no hand in it is not a hand that left, though: everything that watches the hand's *shape* — the mode
/// holds, the pose holds, the pill — does better with the last reading standing in for a moment than with a gap that
/// restarts it. A fist hold that starts over on every third frame never completes.
///
/// What it must not do is let anything happen twice. A reading carries both a state (this shape, this speed) and the
/// events that landed on that one frame (a tap, a knock, a zoom step), so a stand-in reading comes back with those
/// cleared — `GestureReading.withoutEvents`.
///
/// And it only stands in for a shape that had **settled**: two readings in a row, dropouts between them ignored,
/// agreeing on the pose. A single mistracked frame held for 0.2 s is six frames of a shape the user never made,
/// which is long enough to open a mode — one stray open-palm frame in a recording of a pointing hand opened desktop
/// mode, which is how this was found.
///
/// The cursor is deliberately not on this list: `PointerController` gets the real nil, because a held button has to
/// be let go of when the hand is gone and that clock shouldn't be pushed back.
public struct ReadingHold: Sendable {
    /// How long the last reading stands in. Long enough for the two or three frames Vision drops in a row, short
    /// enough that a hand which really left can't finish a hold.
    public var duration: TimeInterval = 0.2

    private var last: (reading: GestureReading, time: TimeInterval)?
    /// The pose of the fresh reading before the last one, to tell a settled shape from a stray frame.
    private var previousPose: StaticPose??
    /// Whether the last fresh reading agreed with the one before it.
    private var settled = false
    /// Whether the reading last returned was a stand-in rather than a fresh one.
    public private(set) var isHolding = false

    public init(duration: TimeInterval = 0.2) {
        self.duration = duration
    }

    /// Feeds what the analyzer made of this frame and returns what the rest of the app should see.
    public mutating func update(_ fresh: GestureReading?, at time: TimeInterval) -> GestureReading? {
        if let fresh {
            settled = previousPose == .some(fresh.pose)
            previousPose = .some(fresh.pose)
            last = (fresh, time)
            isHolding = false
            return fresh
        }
        guard settled, let last, time - last.time <= duration else {
            self.last = nil
            isHolding = false
            return nil
        }
        // Still the same shape as far as anyone knows.
        isHolding = true
        return last.reading.withoutEvents
    }

    public mutating func reset() {
        last = nil
        previousPose = nil
        settled = false
        isHolding = false
    }
}

public extension GestureReading {
    /// The same reading with everything that happened *on* its frame cleared, so standing in for a lost frame can't
    /// fire a tap, a knock, a park or a zoom step a second time.
    var withoutEvents: GestureReading {
        var copy = self
        copy.tap = nil
        copy.fistPump = false
        copy.idleGesture = false
        copy.zoomStep = 0
        copy.steps = []
        return copy
    }
}
