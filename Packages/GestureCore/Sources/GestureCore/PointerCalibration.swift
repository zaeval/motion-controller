import Foundation

/// Setting the cursor's projection by pointing at it: the screen shows its four corners, the user points the index at
/// each one and holds still, and where their hand actually was becomes the interaction box.
///
/// Worth doing because a guessed box is wrong in a way the user feels. The hand-fitted box put this user's resting
/// hand at screen (0.98, 1.00) — the bottom-right corner — so the cursor started in the corner and the top of the
/// screen was a reach.
public struct PointerCalibration: Sendable {
    /// Screen corners, in the order the user is asked for them.
    public enum Corner: String, CaseIterable, Codable, Sendable {
        case topLeft, topRight, bottomRight, bottomLeft
    }

    public struct Settings: Codable, Equatable, Sendable {
        /// The hand must stay within this much of where it landed (image heights) to count as pointing.
        public var steadyRadius = 0.03
        /// ...and stay there this long.
        public var steadySeconds: TimeInterval = 0.8
        /// A hand gone this long starts the corner over.
        public var lostReset: TimeInterval = 0.5
        /// The box is never narrower than this in either direction, so a bad capture can't leave the cursor stuck.
        public var minSpan = 0.15

        public init() {}
    }

    public var settings: Settings
    /// The corner being pointed at; nil once all four are captured.
    public private(set) var corner: Corner?
    /// How far the current hold has come, 0...1, for the overlay.
    public private(set) var progress = 0.0
    private var captured: [Corner: Vec2] = [:]
    private var held: (point: Vec2, since: TimeInterval)?
    private var lastSeen: TimeInterval?

    public init(settings: Settings = Settings()) {
        self.settings = settings
        corner = Corner.allCases.first
    }

    /// How many corners are in the bag, for the overlay.
    public var capturedCount: Int { captured.count }

    /// Feeds the pointer point (nil when no hand was tracked). Returns the box on the frame the last corner lands.
    public mutating func update(_ point: Vec2?, at time: TimeInterval) -> InteractionBox? {
        guard let corner else { return nil }
        if let lastSeen, time - lastSeen > settings.lostReset {
            held = nil
        }
        guard let point else {
            progress = 0
            return nil
        }
        lastSeen = time
        guard let current = held, current.point.distance(to: point) <= settings.steadyRadius else {
            held = (point, time)
            progress = 0
            return nil
        }
        progress = min((time - current.since) / settings.steadySeconds, 1)
        guard progress >= 1 else { return nil }

        captured[corner] = current.point
        held = nil
        progress = 0
        self.corner = Corner.allCases.first { captured[$0] == nil }
        guard self.corner == nil else { return nil }
        return box()
    }

    public mutating func reset() {
        captured = [:]
        held = nil
        progress = 0
        lastSeen = nil
        corner = Corner.allCases.first
    }

    /// The four camera points → the box that maps them onto the screen. Margins are fractions of the mirrored view,
    /// so the screen's left edge sits at high image x: `left` is what's left over beyond it.
    private func box() -> InteractionBox? {
        func mean(_ corners: [Corner], _ value: (Vec2) -> Double) -> Double? {
            let values = corners.compactMap { captured[$0].map(value) }
            guard values.count == corners.count else { return nil }
            return values.reduce(0, +) / Double(values.count)
        }
        guard let leftX = mean([.topLeft, .bottomLeft], \.x),
              let rightX = mean([.topRight, .bottomRight], \.x),
              let topY = mean([.topLeft, .topRight], \.y),
              let bottomY = mean([.bottomLeft, .bottomRight], \.y)
        else { return nil }
        return InteractionBox(left: 1 - leftX, right: rightX, top: 1 - topY, bottom: bottomY)
            .widened(toSpan: settings.minSpan)
    }
}
