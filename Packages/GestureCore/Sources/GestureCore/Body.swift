import Foundation

/// The upper-body joints used to tie hands to a person and to tell people apart.
public enum BodyJoint: Int, CaseIterable, Codable, Sendable {
    case nose, neck
    case leftShoulder, rightShoulder
    case leftElbow, rightElbow
    case leftWrist, rightWrist
}

public struct BoundingBox: Codable, Sendable, Hashable {
    public var minX: Double
    public var minY: Double
    public var maxX: Double
    public var maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public var area: Double { max(0, maxX - minX) * max(0, maxY - minY) }

    public func intersectionOverUnion(with other: BoundingBox) -> Double {
        let overlap = BoundingBox(
            minX: max(minX, other.minX), minY: max(minY, other.minY),
            maxX: min(maxX, other.maxX), maxY: min(maxY, other.maxY)
        ).area
        let union = area + other.area - overlap
        return union > 0 ? overlap / union : 0
    }
}

/// One person in one frame. Positions are Vision-normalized and un-mirrored, like `HandFrame`.
public struct Body: Codable, Sendable {
    /// Indexed by `BodyJoint.rawValue`.
    public var joints: [JointPoint?]
    public var leftHand: HandFrame?
    public var rightHand: HandFrame?
    public var timestamp: TimeInterval
    public var imageAspect: Double

    public init(
        joints: [BodyJoint: JointPoint],
        leftHand: HandFrame? = nil,
        rightHand: HandFrame? = nil,
        timestamp: TimeInterval,
        imageAspect: Double = 4.0 / 3.0
    ) {
        self.joints = [JointPoint?](joints, of: BodyJoint.self)
        self.leftHand = leftHand
        self.rightHand = rightHand
        self.timestamp = timestamp
        self.imageAspect = imageAspect
    }

    public func normalizedPosition(of joint: BodyJoint) -> Vec2? {
        joints.confidentPosition(at: joint.rawValue)
    }

    /// Position in image-height units (x scaled by `imageAspect`).
    public subscript(_ joint: BodyJoint) -> Vec2? {
        normalizedPosition(of: joint).map { Vec2($0.x * imageAspect, $0.y) }
    }

    public var hands: [HandFrame] { [leftHand, rightHand].compactMap { $0 } }

    public func wrist(_ side: Chirality) -> Vec2? {
        side == .left ? self[.leftWrist] : side == .right ? self[.rightWrist] : nil
    }

    public func elbow(_ side: Chirality) -> Vec2? {
        side == .left ? self[.leftElbow] : side == .right ? self[.rightElbow] : nil
    }

    public func shoulder(_ side: Chirality) -> Vec2? {
        side == .left ? self[.leftShoulder] : side == .right ? self[.rightShoulder] : nil
    }

    /// Shoulder-to-shoulder distance, used to pick the person nearest the camera.
    public var shoulderWidth: Double? {
        guard let left = self[.leftShoulder], let right = self[.rightShoulder] else { return nil }
        return left.distance(to: right)
    }

    /// Box around the confident upper-body joints and attached wrists, in image-height units.
    public var boundingBox: BoundingBox? {
        let points = BodyJoint.allCases.compactMap { self[$0] } + hands.compactMap { $0[.wrist] }
        guard let first = points.first, points.count >= 2 else { return nil }
        return points.dropFirst().reduce(BoundingBox(minX: first.x, minY: first.y, maxX: first.x, maxY: first.y)) { box, point in
            BoundingBox(
                minX: min(box.minX, point.x), minY: min(box.minY, point.y),
                maxX: max(box.maxX, point.x), maxY: max(box.maxY, point.y)
            )
        }
    }
}
