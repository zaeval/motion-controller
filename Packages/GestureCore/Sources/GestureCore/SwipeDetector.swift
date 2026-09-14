import Foundation

public enum SwipeDirection: String, Codable, Sendable {
    /// The hand travelled toward the user's left.
    case left
    /// The hand travelled toward the user's right.
    case right

    public var opposite: SwipeDirection { self == .left ? .right : .left }
}

/// Desktop switches: 🖐 held still with the palm to the camera, then swept sideways. The user's call (2026-09-14).
///
/// The detector this replaced took any flat hand travelling sideways, and needed a stack of rules to tell a stroke
/// from its wind-up, its return and everything else a hand does. It still missed strokes, and fired on a fist pulled
/// back to park (logged at 17:19 and 17:34 on 2026-09-14). Holding still first settles all of it: the direction is
/// measured from where the hand stood, so a wind-up the other way never gets far enough, and a hand coming back,
/// reaching for something or folding to park never stood still as an open palm first.
///
/// - Armed: three fingers or more out, the palm toward the camera, no fist or control pinch, and the palm within
///   `stillRadius` for `armSeconds`. Folding into a fist or a pinch before moving off disarms.
/// - Fired: from armed, the palm gets `strokeTravel` sideways from where it stood, more sideways than up or down,
///   within `strokeWindow` of starting to move. A stroke that blurs out of tracking fires if it had got `exitTravel`.
/// - Afterwards only another hold arms it, and the opposite way stays off for `oppositeSuppression`, so pausing at
///   the end of a stroke doesn't make the way back a swipe.
public struct SwipeDetector: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// How long the palm stands still before a sweep is measured from where it stood. Short on purpose: the
        /// user's complaint (2026-09-14) was that switching felt slow, and what they were waiting for was this. It
        /// can't go to zero — the standstill is what gives the stroke an origin, which is how a wind-up and a return
        /// are told from the stroke itself.
        public var armSeconds: TimeInterval = 0.15
        /// How far the palm may wander while it holds still, in image heights.
        public var stillRadius = 0.035
        /// Sideways travel from where the hand stood that makes a swipe, in frame widths. Recorded wind-ups the other
        /// way reached 0.125 at most, measured from where they began.
        public var strokeTravel = 0.13
        /// Travel enough for a stroke that blurred out of tracking before it got to `strokeTravel`.
        public var exitTravel = 0.07
        /// The stroke must get there this soon after the hand starts moving: a drift isn't a swipe.
        public var strokeWindow: TimeInterval = 0.8
        /// Sideways travel must be at least this multiple of the vertical, both in image heights.
        public var axisRatio = 1.2
        /// Moving this far up or down before the stroke gets there disarms, in image heights: the hand came down.
        public var maxRise = 0.2
        /// Tracking gaps up to this long don't break a hold or a stroke. A fast stroke blurs out for a few frames.
        public var dropoutTolerance: TimeInterval = 0.3
        /// No swipe the other way this soon after one. Longer than the arming hold by a lot, because that hold is
        /// now short enough for a hand pausing at the end of a stroke to re-arm before it comes back: logged return
        /// strokes arrived 1.4–1.6 s after the stroke they were returning from.
        public var oppositeSuppression: TimeInterval = 1.6
        public var invert = false

        public init() {}
    }

    public struct Sample: Sendable {
        /// Palm anchor in image-height units.
        public var anchor: Vec2
        /// Three fingers or more out.
        public var flatHand: Bool
        public var pinching: Bool
        public var fist: Bool
        /// Whether the palm faces the camera; nil when it can't be told.
        public var palmFacesCamera: Bool?
        public var imageAspect: Double

        public init(
            anchor: Vec2, flatHand: Bool = true, pinching: Bool = false, fist: Bool = false,
            palmFacesCamera: Bool? = true, imageAspect: Double = 16.0 / 9
        ) {
            self.anchor = anchor
            self.flatHand = flatHand
            self.pinching = pinching
            self.fist = fist
            self.palmFacesCamera = palmFacesCamera
            self.imageAspect = imageAspect
        }

        /// A pinch worth taking for a volume or brightness drag: pinched, and not held flat.
        var isControlPinch: Bool { pinching && !flatHand }
        /// What a hand has to look like on every frame of the hold.
        var canArm: Bool { flatHand && palmFacesCamera == true && !isControlPinch && !fist }
    }

    /// Where the hand stood still, and when it started moving from there.
    private struct Hold: Sendable {
        var anchor: Vec2
        var movedAt: TimeInterval?
    }

    public var settings: Settings
    private var recent: [(time: TimeInterval, anchor: Vec2, canArm: Bool)] = []
    private var hold: Hold?
    private var lastSeen: (time: TimeInterval, anchor: Vec2, aspect: Double)?
    private var lastFire: (direction: SwipeDirection, time: TimeInterval)?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// The hand has held still and a sideways sweep now switches desktops, for the overlay.
    public var isArmed: Bool { hold != nil }

    /// Feeds one frame (nil when no hand was seen). Returns the swipe that completed on this frame, if any.
    public mutating func update(_ sample: Sample?, at time: TimeInterval) -> SwipeDirection? {
        let gap = lastSeen.map { time - $0.time } ?? .infinity
        guard let sample else {
            guard gap > settings.dropoutTolerance else { return nil }
            recent.removeAll()
            // A stroke that blurred out of tracking still happened, if it had got far enough.
            guard let armed = hold, let seen = lastSeen else {
                hold = nil
                return nil
            }
            hold = nil
            guard let direction = stroke(from: armed.anchor, to: seen.anchor, aspect: seen.aspect, travel: settings.exitTravel)
            else { return nil }
            return fire(direction, at: time)
        }
        if gap > settings.dropoutTolerance {
            recent.removeAll()
            hold = nil
        }
        lastSeen = (time, sample.anchor, sample.imageAspect)
        recent.append((time, sample.anchor, sample.canArm))
        // A frame's worth of slack either way, so frame times that don't add up exactly can't flicker the hold.
        recent.removeAll { time - $0.time > settings.armSeconds + 1.0 / 60 }

        // Folding into a fist or pinching a control before moving off: a park or a drag, never a swipe. Once the stroke
        // is under way the shape stops counting: a sweeping hand blurs and turns until it reads as either.
        if hold?.movedAt == nil, sample.fist || sample.isControlPinch {
            hold = nil
            return nil
        }
        if let center = stillCenter(at: time) {
            // The middle of the hold rather than the latest frame, which is already on its way at the start of a stroke.
            hold = Hold(anchor: center)
            return nil
        }
        guard var current = hold else { return nil }
        // Still where it stood, only not looking right for a frame or two: not moving off yet.
        if current.movedAt == nil, sample.anchor.distance(to: current.anchor) <= settings.stillRadius {
            return nil
        }
        let movedAt = current.movedAt ?? time
        current.movedAt = movedAt
        hold = current
        if time - movedAt > settings.strokeWindow || abs(sample.anchor.y - current.anchor.y) > settings.maxRise {
            hold = nil
            return nil
        }
        guard let direction = stroke(
            from: current.anchor, to: sample.anchor, aspect: sample.imageAspect, travel: settings.strokeTravel
        ) else { return nil }
        hold = nil
        // Only a hold that starts after this swipe arms the next one.
        recent.removeAll()
        return fire(direction, at: time)
    }

    public mutating func reset() {
        recent.removeAll()
        hold = nil
        lastSeen = nil
        lastFire = nil
    }

    /// Where the palm has been holding still: every frame of the last `armSeconds` looked right and stayed close
    /// together. Nil otherwise.
    private func stillCenter(at time: TimeInterval) -> Vec2? {
        guard let first = recent.first, time - first.time >= settings.armSeconds - 1.0 / 60,
              recent.allSatisfy(\.canArm)
        else { return nil }
        let count = Double(recent.count)
        let center = Vec2(recent.map(\.anchor.x).reduce(0, +) / count, recent.map(\.anchor.y).reduce(0, +) / count)
        return recent.allSatisfy { $0.anchor.distance(to: center) <= settings.stillRadius } ? center : nil
    }

    /// The swipe from `start` to `end`, if it went `travel` frame widths sideways and more sideways than up or down.
    private func stroke(from start: Vec2, to end: Vec2, aspect: Double, travel: Double) -> SwipeDirection? {
        let sideways = end.x - start.x
        guard abs(sideways) / aspect >= travel, abs(sideways) >= settings.axisRatio * abs(end.y - start.y) else {
            return nil
        }
        // Image x grows toward the user's left: the camera image isn't mirrored.
        let left = sideways > 0
        return left != settings.invert ? .left : .right
    }

    private mutating func fire(_ direction: SwipeDirection, at time: TimeInterval) -> SwipeDirection? {
        if let lastFire, direction != lastFire.direction, time - lastFire.time < settings.oppositeSuppression {
            return nil
        }
        lastFire = (direction, time)
        return direction
    }
}
