import Foundation

/// Thumb–index pinch with separate engage and release thresholds and a short debounce. A sweeping hand
/// can't *start* a pinch — motion blur fakes one (Pawvis measured phantom clicks mid-swipe) — but a pinch
/// already held survives any speed, so drags and pinch-drags keep working. Blur also smears the thumb and index
/// apart while the hand moves, which dropped fast drags, so releasing while moving takes a longer run of frames.
public struct PinchTracker: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Hand sizes. Pawvis engages at 0.45 on real hands; start tighter and tune on recorded sequences.
        public var engageRatio = 0.35
        public var releaseRatio = 0.50
        public var debounceFrames = 2
        /// Consecutive open frames that release a pinch while the hand is moving.
        public var releaseFramesWhileMoving = 4

        public init() {}
    }

    public var settings: Settings
    public private(set) var isPinching = false
    private var pendingFrames = 0

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Missing joints (nil ratio) hold the current state.
    public mutating func update(pinchRatio: Double?, sweeping: Bool, moving: Bool = false) -> Bool {
        guard let ratio = pinchRatio else { return isPinching }
        let wantsChange = isPinching ? ratio > settings.releaseRatio : ratio < settings.engageRatio && !sweeping
        if wantsChange {
            pendingFrames += 1
            let needed = isPinching && moving ? settings.releaseFramesWhileMoving : settings.debounceFrames
            if pendingFrames >= needed {
                isPinching.toggle()
                pendingFrames = 0
            }
        } else {
            pendingFrames = 0
        }
        return isPinching
    }

    public mutating func reset() {
        isPinching = false
        pendingFrames = 0
    }
}
