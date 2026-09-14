import Foundation

/// Setting the cursor's projection by pointing at it: the screen shows its four corners, the user points the index at
/// each one and holds still, and where their hand actually was becomes the interaction box.
///
/// Worth doing because a guessed box is wrong in a way the user feels. The hand-fitted box put this user's resting
/// hand at screen (0.98, 1.00) — the bottom-right corner — so the cursor started in the corner and the top of the
/// screen was a reach.
///
/// Two things the user asked for (2026-09-14) after doing it once: each capture waits for a button press before the
/// next corner is asked for, and every corner is asked for twice with the two samples averaged. Advancing the moment
/// a hold completed meant the hand on its way to the next corner was already being measured for it, and a single
/// sample per corner put a bad one straight into the box with nothing to balance it.
public struct PointerCalibration: Sendable {
    /// Screen corners, in the order the user is asked for them.
    public enum Corner: String, CaseIterable, Codable, Sendable {
        case topLeft, topRight, bottomRight, bottomLeft
    }

    /// How many times each corner is asked for. The samples of one corner are averaged before the box is built.
    public static let rounds = 2

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
    /// The corner being pointed at — or, while `awaitingConfirmation`, the one just captured. nil once the last
    /// capture has been confirmed and the box is out.
    public private(set) var corner: Corner?
    /// Which pass over the four corners `corner` belongs to, 1...`rounds`.
    public private(set) var round = 1
    /// How far the current hold has come, 0...1, for the overlay.
    public private(set) var progress = 0.0
    /// A capture has landed and nothing more is measured until `confirm()` (the panel's button) or `redo()`.
    public private(set) var awaitingConfirmation = false
    private var captured: [Corner: [Vec2]] = [:]
    private var held: (point: Vec2, since: TimeInterval)?
    private var lastSeen: TimeInterval?

    public init(settings: Settings = Settings()) {
        self.settings = settings
        corner = Corner.allCases.first
    }

    /// How many captures are in the bag, out of `totalCaptures`.
    public var capturedCount: Int { captured.values.reduce(0) { $0 + $1.count } }

    /// Every corner, every round.
    public static var totalCaptures: Int { rounds * Corner.allCases.count }

    /// How many times this corner has been captured, for the panel's markers.
    public func captures(of corner: Corner) -> Int { captured[corner]?.count ?? 0 }

    /// Feeds the pointer point (nil when no hand was tracked). Returns true on the frame a capture lands, which is
    /// when the panel puts its button up; the box comes from `confirm()`.
    @discardableResult
    public mutating func update(_ point: Vec2?, at time: TimeInterval) -> Bool {
        guard let corner, !awaitingConfirmation else { return false }
        if let lastSeen, time - lastSeen > settings.lostReset {
            held = nil
        }
        guard let point else {
            progress = 0
            return false
        }
        lastSeen = time
        guard let current = held, current.point.distance(to: point) <= settings.steadyRadius else {
            held = (point, time)
            progress = 0
            return false
        }
        progress = min((time - current.since) / settings.steadySeconds, 1)
        guard progress >= 1 else { return false }

        captured[corner, default: []].append(current.point)
        held = nil
        progress = 0
        awaitingConfirmation = true
        return true
    }

    /// Keeps the waiting capture and asks for the next corner. Returns the box when that was the last one.
    public mutating func confirm() -> InteractionBox? {
        guard awaitingConfirmation else { return nil }
        awaitingConfirmation = false
        held = nil
        progress = 0
        let next = capturedCount
        guard next < Self.totalCaptures else {
            corner = nil
            return box()
        }
        corner = Corner.allCases[next % Corner.allCases.count]
        round = next / Corner.allCases.count + 1
        return nil
    }

    /// Throws the waiting capture away and asks for the same corner again: the user saw where it landed and didn't
    /// like it.
    public mutating func redo() {
        guard awaitingConfirmation, let corner, var samples = captured[corner] else { return }
        samples.removeLast()
        captured[corner] = samples.isEmpty ? nil : samples
        awaitingConfirmation = false
        held = nil
        progress = 0
    }

    public mutating func reset() {
        captured = [:]
        held = nil
        progress = 0
        lastSeen = nil
        awaitingConfirmation = false
        round = 1
        corner = Corner.allCases.first
    }

    /// The captured points → the box that maps them onto the screen. A corner's rounds are averaged first, so each
    /// corner counts the same however many samples it ended up with. Margins are fractions of the mirrored view, so
    /// the screen's left edge sits at high image x: `left` is what's left over beyond it.
    private func box() -> InteractionBox? {
        func mean(_ corners: [Corner], _ value: (Vec2) -> Double) -> Double? {
            let perCorner = corners.compactMap { corner -> Double? in
                guard let samples = captured[corner], !samples.isEmpty else { return nil }
                return samples.map(value).reduce(0, +) / Double(samples.count)
            }
            guard perCorner.count == corners.count else { return nil }
            return perCorner.reduce(0, +) / Double(perCorner.count)
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
