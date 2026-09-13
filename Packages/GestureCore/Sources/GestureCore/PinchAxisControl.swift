import Foundation

public enum ContinuousTarget: String, Codable, Sendable {
    case volume, brightness
}

/// Volume and brightness by pinch-and-drag. Past a deadband the dominant axis is chosen — vertical is volume,
/// horizontal is brightness — and every `step` hand sizes of travel along it emits one step, so a longer drag
/// changes more. The pinch can change axes without letting go: once travel across the current axis since its last
/// step clears the deadband and beats the travel along it by `axisRatio`, the other axis takes over. A diagonal
/// drift keeps stepping the first axis, because every step re-bases that comparison.
public struct PinchAxisControl: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Hand sizes the pinch must travel before an axis is chosen or switched.
        public var deadband = 0.15
        /// Hand sizes of travel per step. At 0.15 macOS's 16 volume steps span about 2.4 hand sizes of arm travel;
        /// 0.25 only managed ±1 for the small drags people actually make.
        public var step = 0.15
        /// The chosen axis must beat the other by this factor.
        public var axisRatio = 1.5

        public init() {}
    }

    public enum Axis: Sendable, Equatable {
        case vertical, horizontal

        public var target: ContinuousTarget { self == .vertical ? .volume : .brightness }
    }

    public struct Step: Equatable, Sendable {
        public var target: ContinuousTarget
        /// +1 is louder / brighter.
        public var delta: Int

        public init(target: ContinuousTarget, delta: Int) {
            self.target = target
            self.delta = delta
        }
    }

    public var settings: Settings
    public private(set) var isEngaged = false
    public private(set) var axis: Axis?
    /// Net steps per target since the pinch engaged, so the overlay and log can show how far a drag has gone.
    public private(set) var totals: [ContinuousTarget: Int] = [:]
    private var origin = Vec2.zero
    /// Hand size captured at engage, so steps don't stretch as the hand moves nearer or farther.
    private var unit = 0.0
    private var stepOrigin = 0.0
    /// Where travel is measured from when deciding whether the other axis has taken over.
    private var reference = Vec2.zero

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public func total(for target: ContinuousTarget) -> Int {
        totals[target, default: 0]
    }

    /// `anchor` in image-height units, `handSize` in the same units.
    public mutating func update(pinching: Bool, anchor: Vec2?, handSize: Double?) -> [Step] {
        guard pinching else {
            reset()
            return []
        }
        guard let anchor else { return [] }

        guard isEngaged else {
            guard let handSize, handSize > 0 else { return [] }
            isEngaged = true
            origin = anchor
            unit = handSize
            axis = nil
            totals = [:]
            return []
        }

        guard let current = axis else {
            if let chosen = dominantAxis(of: anchor - origin) {
                lock(chosen, at: anchor)
            }
            return []
        }

        if let chosen = dominantAxis(of: anchor - reference), chosen != current {
            lock(chosen, at: anchor)
            return []
        }

        let position = value(of: anchor, along: current)
        let stepSize = settings.step * unit
        var steps: [Step] = []
        while position - stepOrigin >= stepSize {
            stepOrigin += stepSize
            steps.append(Step(target: current.target, delta: 1))
        }
        while stepOrigin - position >= stepSize {
            stepOrigin -= stepSize
            steps.append(Step(target: current.target, delta: -1))
        }
        if !steps.isEmpty {
            totals[current.target, default: 0] += steps.reduce(0) { $0 + $1.delta }
            reference = anchor
        }
        return steps
    }

    public mutating func reset() {
        isEngaged = false
        axis = nil
        totals = [:]
    }

    /// The axis a displacement clearly favors once it clears the deadband; nil while it is small or diagonal.
    private func dominantAxis(of delta: Vec2) -> Axis? {
        let horizontal = abs(delta.x)
        let vertical = abs(delta.y)
        guard max(horizontal, vertical) >= settings.deadband * unit else { return nil }
        if vertical >= settings.axisRatio * horizontal { return .vertical }
        if horizontal >= settings.axisRatio * vertical { return .horizontal }
        return nil
    }

    private mutating func lock(_ axis: Axis, at anchor: Vec2) {
        self.axis = axis
        stepOrigin = value(of: anchor, along: axis)
        reference = anchor
    }

    /// Increasing is louder / brighter: up for volume; the user's right, which is image-left un-mirrored, for brightness.
    private func value(of point: Vec2, along axis: Axis) -> Double {
        axis == .vertical ? point.y : -point.x
    }
}
