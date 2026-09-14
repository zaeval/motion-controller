import Foundation

/// Zoom by holding three fingers up and moving the hand up or down: every `step` hand sizes of travel is one step, and
/// up zooms in. The hand size is captured when the pose engages, so strides don't stretch as the hand nears the camera.
///
/// Each step is one press of the Zoom shortcut, a big change on screen. Stepping once per tenth of the cursor box, a
/// few seconds of 🤟 fired 189 steps, up to seven on one frame, swinging in and out (logged 2026-09-14). So a frame
/// steps at most once, steps keep a minimum gap, travel left over after a step is dropped rather than owed, and a jump
/// between frames bigger than any hand moves — the wrist, or the tracked hand itself, hopping — starts travel over
/// instead of stepping. The first cut of that, a step per 0.45 hand sizes at most every 0.15 s, went a median 0.5 s
/// between steps and looked choppy, so strides are shorter and steps may come every third frame.
public struct ZoomControl: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Hand sizes of vertical travel per step.
        public var step = 0.25
        /// Frames the pose must hold before travel counts: a hand closing into a fist passes through three fingers for a
        /// frame or two.
        public var engageFrames = 4
        /// Steps are at least this far apart: every third frame at 30 fps.
        public var minStepInterval: TimeInterval = 0.09
        /// A move between frames bigger than this, in hand sizes, is a tracking jump.
        public var maxJump = 0.6

        public init() {}
    }

    public var settings: Settings
    public private(set) var isEngaged = false
    private var heldFrames = 0
    /// Hand size captured at engage.
    private var unit = 0.0
    /// Height the next step is measured from.
    private var origin = 0.0
    private var previous = 0.0
    private var lastStep = -TimeInterval.infinity

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Feeds one frame: whether three fingers are held, and the palm anchor and hand size in image-height units (y up).
    /// Returns +1 to zoom in, -1 to zoom out, 0 for neither.
    public mutating func update(active: Bool, anchor: Vec2?, handSize: Double?, at time: TimeInterval) -> Int {
        guard active, let anchor else {
            reset()
            return 0
        }
        guard isEngaged else {
            heldFrames += 1
            guard heldFrames >= settings.engageFrames, let handSize, handSize > 0 else { return 0 }
            isEngaged = true
            unit = handSize
            origin = anchor.y
            previous = anchor.y
            return 0
        }
        defer { previous = anchor.y }
        if abs(anchor.y - previous) > settings.maxJump * unit {
            origin = anchor.y
            return 0
        }
        let travel = anchor.y - origin
        guard abs(travel) >= settings.step * unit, time - lastStep >= settings.minStepInterval else { return 0 }
        origin = anchor.y
        lastStep = time
        return travel > 0 ? 1 : -1
    }

    public mutating func reset() {
        isEngaged = false
        heldFrames = 0
    }
}
