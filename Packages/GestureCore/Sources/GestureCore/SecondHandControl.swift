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
/// Shapes rather than taps, also their call: a shape appearing is far easier to see than a finger dipping for two
/// frames, and on a hand that isn't carrying the cursor there is nothing to lose by changing it.
///
/// - ☝️ index alone → click. Show it twice in quick succession for a double-click; `PointerController` chains those.
/// - ✌️ two fingers → right click.
/// - ✊ fist → the button goes down and stays down; opening the hand lets go. That is the drag, and unlike a pinch on
///   the cursor hand it can't nudge the pointer.
/// - 🖐 flat hand moving up or down → scroll.
///
/// Each shape acts once, when it settles; it has to change to something else before it can act again. A hand that
/// goes missing lets go of anything it was holding.
public struct SecondHandControl: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Frames the same shape has to hold before it counts.
        public var candidateFrames = 3
        /// Vertical travel per scroll step, in image heights.
        public var scrollStep = 0.02
        /// A hand gone this long is gone: it lets go and the next shape counts afresh.
        public var lostGrace: TimeInterval = 0.2

        public init() {}
    }

    public struct Sample: Sendable {
        public var pose: StaticPose?
        /// Palm anchor in image-height units.
        public var anchor: Vec2

        public init(pose: StaticPose?, anchor: Vec2) {
            self.pose = pose
            self.anchor = anchor
        }
    }

    public var settings: Settings
    /// The shape that has held long enough to mean something, for the overlay.
    public private(set) var pose: StaticPose?
    /// The button is being held by a fist.
    public private(set) var isPressing = false
    private var candidatePose: StaticPose?
    private var candidateFrames = 0
    private var scrollAnchor: Double?
    private var lastSeen: TimeInterval?

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
        if candidatePose == sample.pose {
            candidateFrames += 1
        } else {
            candidatePose = sample.pose
            candidateFrames = 1
        }
        guard candidateFrames >= settings.candidateFrames, candidatePose != pose else {
            // The settled shape hasn't changed; a flat hand keeps scrolling while it is held.
            return Self.scrolls(pose) ? scroll(to: sample.anchor.y) : []
        }
        var intents: [SecondHandIntent] = []
        if isPressing {
            isPressing = false
            intents.append(.release)
        }
        pose = candidatePose
        scrollAnchor = nil
        switch pose {
        case .pointIndex?:
            intents.append(.click)
        case .victory?:
            intents.append(.rightClick)
        case .fist?:
            isPressing = true
            intents.append(.press)
        case let settled? where Self.scrolls(settled):
            scrollAnchor = sample.anchor.y
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
        lastSeen = nil
        return intents
    }
}
