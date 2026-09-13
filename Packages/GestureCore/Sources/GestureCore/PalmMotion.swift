import Foundation

/// Palm anchor speed in image heights per second. Samples more than 0.2 s apart give no reading.
public struct PalmMotion: Sendable {
    public private(set) var speed = 0.0
    private var last: (point: Vec2, time: TimeInterval)?

    public init() {}

    public mutating func update(anchor: Vec2?, at time: TimeInterval) {
        guard let anchor else { return }
        if let last, time > last.time, time - last.time <= 0.2 {
            speed = anchor.distance(to: last.point) / (time - last.time)
        } else {
            speed = 0
        }
        last = (anchor, time)
    }

    public mutating func reset() {
        speed = 0
        last = nil
    }
}
