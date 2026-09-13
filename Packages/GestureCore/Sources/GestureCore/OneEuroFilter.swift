// Adapted from Pawvis (MIT, © 2026 Alexandria Redmon), Sources/PawvisCore/Geometry/OneEuroFilter.swift.
// See THIRD_PARTY_NOTICES.md.

import Foundation

/// The One Euro filter (Casiez, Roussel, Vogel 2012): smooths hard at low speed (kills jitter)
/// and lightly at high speed (kills lag). dt is floored at 1e-4 s and the derivative is taken
/// against the previous filtered value, which keeps it stable.
public struct OneEuroFilter: Sendable {
    public struct Params: Codable, Equatable, Sendable {
        /// Baseline cutoff in Hz. Lower is smoother at rest.
        public var minCutoff: Double
        /// Speed coefficient. Higher is snappier during fast motion.
        public var beta: Double
        /// Cutoff for the derivative estimate, in Hz.
        public var dCutoff: Double

        public init(minCutoff: Double = 1.4, beta: Double = 0.014, dCutoff: Double = 1.0) {
            self.minCutoff = minCutoff
            self.beta = beta
            self.dCutoff = dCutoff
        }

        public static let landmark = Params()
        /// Pawvis's cursor tuning: lag is more noticeable than jitter when driving a pointer.
        public static let cursor = Params(minCutoff: 1.4, beta: 0.03, dCutoff: 1.0)
    }

    public var params: Params

    private var hasPrevious = false
    private var previousTime: Double = 0
    private var previousValue: Double = 0
    private var previousDerivative: Double = 0

    public init(params: Params = Params()) {
        self.params = params
    }

    private static func smoothingFactor(cutoffHz: Double, dt: Double) -> Double {
        let r = 2 * .pi * cutoffHz * dt
        return r / (r + 1)
    }

    /// Filters one sample taken at `time` (seconds, increasing).
    public mutating func filter(_ value: Double, at time: Double) -> Double {
        guard hasPrevious else {
            hasPrevious = true
            previousTime = time
            previousValue = value
            previousDerivative = 0
            return value
        }
        let dt = max(time - previousTime, 1e-4)
        let rawDerivative = (value - previousValue) / dt
        let derivativeAlpha = Self.smoothingFactor(cutoffHz: params.dCutoff, dt: dt)
        let derivative = derivativeAlpha * rawDerivative + (1 - derivativeAlpha) * previousDerivative
        let cutoff = params.minCutoff + params.beta * abs(derivative)
        let alpha = Self.smoothingFactor(cutoffHz: cutoff, dt: dt)
        let filtered = alpha * value + (1 - alpha) * previousValue
        previousTime = time
        previousValue = filtered
        previousDerivative = derivative
        return filtered
    }

    public mutating func reset() {
        hasPrevious = false
        previousDerivative = 0
    }
}

/// Independent One Euro filters on x and y.
public struct OneEuroFilter2D: Sendable {
    private var xFilter: OneEuroFilter
    private var yFilter: OneEuroFilter

    public init(params: OneEuroFilter.Params = .init()) {
        xFilter = OneEuroFilter(params: params)
        yFilter = OneEuroFilter(params: params)
    }

    public var params: OneEuroFilter.Params {
        get { xFilter.params }
        set {
            xFilter.params = newValue
            yFilter.params = newValue
        }
    }

    public mutating func filter(_ point: Vec2, at time: Double) -> Vec2 {
        Vec2(xFilter.filter(point.x, at: time), yFilter.filter(point.y, at: time))
    }

    public mutating func reset() {
        xFilter.reset()
        yFilter.reset()
    }
}
