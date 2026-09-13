import Foundation

/// Whether the index is held bent toward the camera, which is what lets the hand move the cursor: with the index
/// straight the hand moves freely, like a finger lifted off a trackpad.
///
/// Measured along the palm in knuckle spans (`HandFeatures.reachAlongPalm`), recorded straight fingers
/// (Tests/GestureCoreTests/Fixtures/sequences, `cursor-idle` and `left-click`) reach 1.10–1.23, a V sign's index
/// 1.04–1.16, and fingers bent to move the cursor (`cursor-move`) 0.65–0.98. That still leaves no fixed line, so a
/// bend is judged against how far this index recently reached while it wasn't bent. The straight reach stays frozen
/// while the finger is bent, so a long cursor move can't sink it until the bend stops counting, and a hand's first
/// frames set it: an index that arrives bent reads as straight until it has been seen straighter. A tap dips further
/// than any bend for a few frames, so the frames of a tap in progress change nothing.
public struct IndexBendDetector: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Bent once the index reaches less than this fraction of its straight reach for `bendFrames` frames...
        public var bendFraction = 0.86
        public var bendFrames = 3
        /// ...and straight again above this fraction for `straightenFrames` frames.
        public var straightenFraction = 0.92
        public var straightenFrames = 2
        /// Shorter than this (knuckle spans) the index is folded into a fist or mistracked, and changes nothing.
        public var minReach = 0.35
        /// The straight reach is this percentile of the unbent reaches in the window, once there are enough of them.
        public var straightPercentile = 0.8
        public var straightWindow: TimeInterval = 6
        public var minStraightSamples = 8
        /// A hand gone this long starts over: the finger may come back held differently.
        public var lostReset: TimeInterval = 1.5

        public init() {}
    }

    public var settings: Settings
    public private(set) var isBent = false
    /// How far the index reaches when straight, in knuckle spans; nil until enough of it has been seen.
    public private(set) var straightReach: Double?
    private var unbent: [(time: TimeInterval, reach: Double)] = []
    private var pendingFrames = 0
    private var lastSeen: TimeInterval?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Feeds the index's reach along the palm, nil when the hand or the finger wasn't tracked, and whether this frame
    /// belongs to a tap in progress. Returns `isBent`.
    public mutating func update(_ reach: Double?, at time: TimeInterval, holding: Bool = false) -> Bool {
        if let lastSeen, time - lastSeen > settings.lostReset {
            reset()
        }
        guard let reach else { return isBent }
        lastSeen = time
        guard !holding, reach >= settings.minReach else { return isBent }

        unbent.removeAll { time - $0.time > settings.straightWindow }
        if !isBent, unbent.count >= settings.minStraightSamples {
            let sorted = unbent.map(\.reach).sorted()
            straightReach = sorted[min(Int(Double(sorted.count) * settings.straightPercentile), sorted.count - 1)]
        }
        if let straight = straightReach {
            let crossing = isBent ? reach > straight * settings.straightenFraction : reach < straight * settings.bendFraction
            pendingFrames = crossing ? pendingFrames + 1 : 0
            if pendingFrames >= (isBent ? settings.straightenFrames : settings.bendFrames) {
                isBent.toggle()
                pendingFrames = 0
            }
        }
        if !isBent {
            unbent.append((time, reach))
        }
        return isBent
    }

    public mutating func reset() {
        isBent = false
        straightReach = nil
        unbent.removeAll()
        pendingFrames = 0
        lastSeen = nil
    }
}
