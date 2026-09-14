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
/// - Afterwards, for `repeatWindow`, the next sweep starts from wherever the hand turns around instead of from
///   another standstill: the user (2026-09-14) found waiting between sweeps the hardest part, and a sweep is only
///   ever heard in desktop mode, which they asked for by showing the palm in the first place.
/// - The hand coming back from a sweep ends up about where that sweep started, so a sweep the other way that ends
///   within `returnTolerance` of the last one's origin is the return and fires nothing. A deliberate sweep the other
///   way carries on past that point, which is what tells the two apart — a timer can't, because a return can come
///   1.4 s later or straight away.
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
        /// How long after a swipe the next one may start from a turning point rather than a standstill.
        public var repeatWindow: TimeInterval = 3.0
        /// How far back from the far end of a sweep the hand has to come before that end counts as a turning point,
        /// in image heights. Bigger than the jitter a hand standing still shows (`stillRadius` allows 0.035 of it),
        /// or tracking noise alone would keep declaring turning points.
        public var reversalTravel = 0.045
        /// A sweep the other way that ends this close to where the last one started is the hand coming back rather
        /// than a sweep, in image heights. A stroke itself travels about 0.23 of those, so the two don't overlap.
        public var returnTolerance = 0.1
        /// A debounce on the other direction, nothing more: `returnTolerance` is what tells a return from a sweep.
        public var oppositeSuppression: TimeInterval = 0.3
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

    /// Which way the hand is travelling and how far it has got, so the point it turns around at can arm the next
    /// sweep without a standstill.
    private struct Turn: Sendable {
        var extreme: Vec2
        /// +1 when image x is growing, -1 when it is shrinking.
        var direction: Double
    }

    public var settings: Settings
    private var recent: [(time: TimeInterval, anchor: Vec2, canArm: Bool)] = []
    private var hold: Hold?
    private var lastSeen: (time: TimeInterval, anchor: Vec2, aspect: Double)?
    private var turn: Turn?
    private var lastFire: (direction: SwipeDirection, time: TimeInterval, origin: Vec2)?

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
            return fire(direction, from: armed.anchor, to: seen.anchor, at: time)
        }
        if gap > settings.dropoutTolerance {
            recent.removeAll()
            hold = nil
            turn = nil
        }
        let previousAnchor = lastSeen?.anchor
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
            turn = nil
            return nil
        }
        // Sweeping again doesn't mean standing still again: within `repeatWindow` of a swipe, the far end of each
        // movement arms the next one. Only while nothing is armed — a stroke under way must keep the origin it
        // started from, or jitter part way through would re-measure it from where it had already got to.
        if hold == nil, let last = lastFire, time - last.time <= settings.repeatWindow, sample.canArm {
            armFromTurn(sample.anchor, previous: previousAnchor)
        } else if hold == nil {
            turn = nil
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
        recent.removeAll()
        return fire(direction, from: current.anchor, to: sample.anchor, at: time)
    }

    public mutating func reset() {
        recent.removeAll()
        hold = nil
        lastSeen = nil
        turn = nil
        lastFire = nil
    }

    /// Follows which way the hand is going, and arms at the far end the moment it comes back from it.
    private mutating func armFromTurn(_ anchor: Vec2, previous: Vec2?) {
        guard var current = turn else {
            guard let previous, previous.x != anchor.x else { return }
            turn = Turn(extreme: anchor, direction: anchor.x > previous.x ? 1 : -1)
            return
        }
        let travelled = (anchor.x - current.extreme.x) * current.direction
        if travelled > 0 {
            current.extreme = anchor
            turn = current
            return
        }
        guard -travelled >= settings.reversalTravel else {
            turn = current
            return
        }
        hold = Hold(anchor: current.extreme)
        turn = Turn(extreme: anchor, direction: -current.direction)
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

    private mutating func fire(
        _ direction: SwipeDirection, from origin: Vec2, to end: Vec2, at time: TimeInterval
    ) -> SwipeDirection? {
        if let lastFire, direction != lastFire.direction {
            if time - lastFire.time < settings.oppositeSuppression { return nil }
            // The hand coming back from the last sweep: it ends up about where that sweep started, while a sweep
            // meant the other way carries on past it. `lastFire` is left alone so the sweep after this one still
            // measures itself against the real one.
            if abs(end.x - lastFire.origin.x) <= settings.returnTolerance { return nil }
        }
        lastFire = (direction, time, origin)
        return direction
    }
}
