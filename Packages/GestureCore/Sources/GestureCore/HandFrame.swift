import Foundation

/// The 21 hand joints Vision reports, in a fixed order so frames serialize as flat arrays.
public enum HandJoint: Int, CaseIterable, Codable, Sendable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

public enum Chirality: String, Codable, Sendable {
    case left, right, unknown
}

public struct JointPoint: Codable, Sendable, Hashable {
    /// Joints below this confidence are treated as missing everywhere.
    public static let minimumConfidence = 0.3

    /// Vision-normalized position: 0...1 on each axis, origin bottom-left, un-mirrored.
    public var position: Vec2
    public var confidence: Double

    public init(position: Vec2, confidence: Double) {
        self.position = position
        self.confidence = confidence
    }
}

extension [JointPoint?] {
    init<Joint: RawRepresentable & CaseIterable>(_ points: [Joint: JointPoint], of _: Joint.Type) where Joint.RawValue == Int {
        self.init(repeating: nil, count: Joint.allCases.count)
        for (joint, point) in points {
            self[joint.rawValue] = point
        }
    }

    func confidentPosition(at index: Int) -> Vec2? {
        guard indices.contains(index),
              let point = self[index],
              point.confidence >= JointPoint.minimumConfidence
        else { return nil }
        return point.position
    }
}

/// One hand in one camera frame. Positions come from the un-mirrored buffer,
/// so `chirality == .right` is the person's physical right hand.
public struct HandFrame: Codable, Sendable {
    /// Indexed by `HandJoint.rawValue`; nil where Vision reported nothing.
    public var joints: [JointPoint?]
    public var chirality: Chirality
    public var timestamp: TimeInterval
    /// Source image width / height. Vision normalizes each axis separately, so geometry scales x
    /// by this to measure distances and angles in a single unit (image heights).
    public var imageAspect: Double

    public init(
        joints: [HandJoint: JointPoint],
        chirality: Chirality,
        timestamp: TimeInterval,
        imageAspect: Double = 4.0 / 3.0
    ) {
        self.joints = [JointPoint?](joints, of: HandJoint.self)
        self.chirality = chirality
        self.timestamp = timestamp
        self.imageAspect = imageAspect
    }

    /// Vision-normalized position, for drawing and camera→screen mapping. Nil when missing or unconfident.
    public func normalizedPosition(of joint: HandJoint) -> Vec2? {
        joints.confidentPosition(at: joint.rawValue)
    }

    /// Position in image-height units (x scaled by `imageAspect`). Nil when missing or unconfident.
    public subscript(_ joint: HandJoint) -> Vec2? {
        normalizedPosition(of: joint).map { Vec2($0.x * imageAspect, $0.y) }
    }

    /// Wrist→middleMCP distance: the unit every hand-relative threshold is measured in.
    public var handSize: Double? {
        guard let wrist = self[.wrist], let middleMCP = self[.middleMCP] else { return nil }
        let size = wrist.distance(to: middleMCP)
        return size > 0 ? size : nil
    }
}
