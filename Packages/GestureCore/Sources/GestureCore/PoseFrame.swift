import Foundation

/// Everything Vision found in one camera frame.
public struct PoseFrame: Codable, Sendable {
    public var bodies: [Body]
    /// Hands with no owning body, e.g. a hand raised close to the camera with the shoulders cropped out.
    public var looseHands: [HandFrame]
    public var timestamp: TimeInterval
    /// Source image width / height.
    public var imageAspect: Double

    public init(bodies: [Body], looseHands: [HandFrame], timestamp: TimeInterval, imageAspect: Double = 4.0 / 3.0) {
        self.bodies = bodies
        self.looseHands = looseHands
        self.timestamp = timestamp
        self.imageAspect = imageAspect
    }

    public var allHands: [HandFrame] { bodies.flatMap(\.hands) + looseHands }

    /// Someone is in front of the camera: a body whose nose or neck is tracked. Every recorded hand came with one.
    public var hasPerson: Bool {
        bodies.contains { $0.normalizedPosition(of: .nose) != nil || $0.normalizedPosition(of: .neck) != nil }
    }
}
