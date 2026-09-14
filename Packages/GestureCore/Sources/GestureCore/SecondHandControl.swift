import Foundation

/// What the hand that isn't driving the cursor is asking for.
public enum SecondHandIntent: Equatable, Sendable {
    case click
    case rightClick
    /// Hold the button down until `release`.
    case press
    case release
    /// Vertical travel since the last step, in image heights; positive means the hand went up.
    case scroll(Double)
}

/// Turns the other hand's shape into clicks, so the hand on the cursor never has to change shape.
///
/// The user's problem (2026-09-14): moving the cursor with one hand and then clicking with the same hand is hard —
/// the tap, the ✌️ for a right click and the pinch for a drag all move the pointer at the moment precision matters
/// most. The hand that started moving the cursor keeps it, and the other hand does the buttons.
///
/// The shape decides what the hand means, which is easy to see, and only the click waits for a finger to move:
///
/// - ☝️ index alone gets ready, and then **bending the index and straightening it again** clicks — the user's call
///   (2026-09-14): raising a finger shouldn't already be a click, because getting the hand into position is not an
///   instruction. Two clicks in quick succession double-click; `PointerController` chains those.
/// - ✌️ two fingers, then the same bend of the index → right click.
/// - ✊ fist → the button goes down and stays down; opening the hand lets go. That is the drag, and unlike a pinch on
///   the cursor hand it can't nudge the pointer.
/// - 🖐 flat hand moving up or down → scroll.
///
/// The fist and the flat hand act on the shape itself; the two clicking shapes act on the bend, so they can click
/// again and again without being lowered. While a bend is under way the settled shape is held, which is also what
/// keeps a bending index — briefly a closed hand — from reading as the fist. A hand that goes missing lets go of
/// anything it was holding.
public struct SecondHandControl: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Frames the same shape has to hold before it counts.
        public var candidateFrames = 3
        /// Vertical travel per scroll step, in image heights.
        public var scrollStep = 0.02
        /// A hand gone this long is gone: it lets go and the next shape counts afresh.
        public var lostGrace: TimeInterval = 0.2
        /// The index has bent once its reach falls below this fraction of how far it was reaching...
        public var dipFraction = 0.72
        /// ...and the click lands when it is back above this fraction. Both from `TapDetector`, measured there.
        public var recoverFraction = 0.85
        /// A bend held longer than this is a finger being folded rather than clicked; the reach it settles at becomes
        /// the new straight one.
        public var maxDipSeconds: TimeInterval = 0.45
        /// A finger reaching less than this (hand sizes) is already folded and has nothing to bend.
        public var minStraightReach = 0.6

        public init() {}
    }

    public struct Sample: Sendable {
        public var pose: StaticPose?
        /// Palm anchor in image-height units.
        public var anchor: Vec2
        /// Index tip → its own knuckle, in hand sizes: how far the index is reaching.
        public var indexReach: Double?

        public init(pose: StaticPose?, anchor: Vec2, indexReach: Double? = nil) {
            self.pose = pose
            self.anchor = anchor
            self.indexReach = indexReach
        }
    }

    public var settings: Settings
    /// The shape that has held long enough to mean something, for the overlay.
    public private(set) var pose: StaticPose?
    /// The button is being held by a fist.
    public private(set) var isPressing = false
    /// A clicking shape is settled and waiting for the bend.
    public var isArmed: Bool { Self.clicks(pose) }
    private var candidatePose: StaticPose?
    private var candidateFrames = 0
    private var scrollAnchor: Double?
    private var lastSeen: TimeInterval?
    /// How far the index reaches when straight, learnt while the shape is settled.
    private var straightReach: Double?
    /// When the index started bending.
    private var dipSince: TimeInterval?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Feeds one frame of the other hand (nil when there isn't one) and returns what it asks for.
    public mutating func update(_ sample: Sample?, at time: TimeInterval) -> [SecondHandIntent] {
        guard let sample else {
            guard let lastSeen, time - lastSeen > settings.lostGrace else { return [] }
            return letGo()
        }
        lastSeen = time
        // A bending index reads as a closed hand for a frame or two: the settled shape is held until the bend is
        // done, so it can't turn into the fist's press.
        if dipSince != nil {
            return dip(sample.indexReach, at: time)
        }
        if candidatePose == sample.pose {
            candidateFrames += 1
        } else {
            candidatePose = sample.pose
            candidateFrames = 1
        }
        guard candidateFrames >= settings.candidateFrames, candidatePose != pose else {
            // The settled shape hasn't changed: a flat hand keeps scrolling, a clicking shape watches for the bend.
            if Self.scrolls(pose) { return scroll(to: sample.anchor.y) }
            return Self.clicks(pose) ? dip(sample.indexReach, at: time) : []
        }
        var intents: [SecondHandIntent] = []
        if isPressing {
            isPressing = false
            intents.append(.release)
        }
        pose = candidatePose
        scrollAnchor = nil
        straightReach = nil
        switch pose {
        case .fist?:
            isPressing = true
            intents.append(.press)
        case let settled? where Self.scrolls(settled):
            scrollAnchor = sample.anchor.y
        case let settled? where Self.clicks(settled):
            // Ready, not clicked: the bend is the click.
            intents += dip(sample.indexReach, at: time)
        default:
            break
        }
        return intents
    }

    public mutating func reset() {
        _ = letGo()
    }

    /// A flat hand, whichever way it is facing: a raised hand reads as either while it moves.
    private static func scrolls(_ pose: StaticPose?) -> Bool {
        pose == .openPalm || pose == .backOfHand
    }

    /// The two shapes whose index bend clicks.
    private static func clicks(_ pose: StaticPose?) -> Bool {
        pose == .pointIndex || pose == .victory
    }

    /// Watches the index of a settled clicking shape: down past `dipFraction` and back up past `recoverFraction` is
    /// the click. A bend that stays down is the finger being folded, and where it settles becomes the new straight.
    private mutating func dip(_ reach: Double?, at time: TimeInterval) -> [SecondHandIntent] {
        guard let reach else { return [] }
        guard let straight = straightReach else {
            if reach >= settings.minStraightReach { straightReach = reach }
            return []
        }
        guard let since = dipSince else {
            if reach <= straight * settings.dipFraction {
                dipSince = time
            } else {
                straightReach = max(straight, reach)
            }
            return []
        }
        if time - since > settings.maxDipSeconds {
            dipSince = nil
            straightReach = nil
            return []
        }
        guard reach >= straight * settings.recoverFraction else { return [] }
        dipSince = nil
        return [pose == .victory ? .rightClick : .click]
    }

    private mutating func scroll(to y: Double) -> [SecondHandIntent] {
        guard let anchor = scrollAnchor else {
            scrollAnchor = y
            return []
        }
        let travel = y - anchor
        guard abs(travel) >= settings.scrollStep else { return [] }
        scrollAnchor = y
        return [.scroll(travel)]
    }

    private mutating func letGo() -> [SecondHandIntent] {
        let intents: [SecondHandIntent] = isPressing ? [.release] : []
        isPressing = false
        pose = nil
        candidatePose = nil
        candidateFrames = 0
        scrollAnchor = nil
        straightReach = nil
        dipSince = nil
        lastSeen = nil
        return intents
    }
}
