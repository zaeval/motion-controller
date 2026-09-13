import Foundation

/// A point or vector in Vision's normalized image space (0...1, origin bottom-left, un-mirrored).
public struct Vec2: Codable, Sendable, Hashable {
    public var x: Double
    public var y: Double

    public init(_ x: Double, _ y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = Vec2(0, 0)

    public var length: Double { (x * x + y * y).squareRoot() }

    public func distance(to other: Vec2) -> Double { (self - other).length }

    public func dot(_ other: Vec2) -> Double { x * other.x + y * other.y }

    public func midpoint(with other: Vec2) -> Vec2 { (self + other) / 2 }

    /// Angle at `vertex` between the rays toward `a` and `b`, in radians (π = straight line).
    public static func angle(at vertex: Vec2, from a: Vec2, to b: Vec2) -> Double {
        let u = a - vertex
        let v = b - vertex
        let lengths = u.length * v.length
        guard lengths > 0 else { return 0 }
        return acos(min(max(u.dot(v) / lengths, -1), 1))
    }

    /// z of the 3D cross product; its sign says which way `other` turns from `self`.
    public func cross(_ other: Vec2) -> Double { x * other.y - y * other.x }

    public static func + (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x + b.x, a.y + b.y) }
    public static func - (a: Vec2, b: Vec2) -> Vec2 { Vec2(a.x - b.x, a.y - b.y) }
    public static func * (a: Vec2, s: Double) -> Vec2 { Vec2(a.x * s, a.y * s) }
    public static func / (a: Vec2, s: Double) -> Vec2 { Vec2(a.x / s, a.y / s) }
}
