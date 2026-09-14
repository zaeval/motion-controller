import Foundation
import GestureCore
import Vision

/// Converts Vision observations into GestureCore's framework-free models.
enum VisionMapping {
    /// `side` overrides Vision's own chirality when the hand came from a body (`leftHand`/`rightHand`). `crop` is
    /// the region of interest the request ran on, when it ran on one: a pose request's points come back normalized to
    /// that region, so they are put back into the whole image's coordinates here.
    static func hand(
        from observation: HumanHandPoseObservation, side: GestureCore.Chirality?, aspect: Double,
        at time: TimeInterval, crop: CGRect? = nil
    ) -> HandFrame {
        var joints: [HandJoint: JointPoint] = [:]
        for joint in HandJoint.allCases {
            if let point = observation.joint(for: joint.visionName) {
                joints[joint] = JointPoint(point, crop: crop)
            }
        }
        let visionChirality: GestureCore.Chirality? = observation.chirality.map { $0 == .left ? .left : .right }
        return HandFrame(joints: joints, chirality: side ?? visionChirality ?? .unknown, timestamp: time, imageAspect: aspect)
    }

    static func body(from observation: HumanBodyPoseObservation, aspect: Double, at time: TimeInterval, includeHands: Bool) -> Body {
        var joints: [BodyJoint: JointPoint] = [:]
        for joint in BodyJoint.allCases {
            if let point = observation.joint(for: joint.visionName) {
                joints[joint] = JointPoint(point)
            }
        }
        return Body(
            joints: joints,
            leftHand: includeHands ? observation.leftHand.map { hand(from: $0, side: .left, aspect: aspect, at: time) } : nil,
            rightHand: includeHands ? observation.rightHand.map { hand(from: $0, side: .right, aspect: aspect, at: time) } : nil,
            timestamp: time,
            imageAspect: aspect
        )
    }
}

private extension JointPoint {
    init(_ joint: Joint, crop: CGRect? = nil) {
        var position = Vec2(Double(joint.location.x), Double(joint.location.y))
        if let crop {
            position = Vec2(
                Double(crop.minX) + position.x * Double(crop.width),
                Double(crop.minY) + position.y * Double(crop.height)
            )
        }
        self.init(position: position, confidence: Double(joint.confidence))
    }
}

private extension HandJoint {
    var visionName: HumanHandPoseObservation.JointName {
        switch self {
        case .wrist: .wrist
        case .thumbCMC: .thumbCMC
        case .thumbMP: .thumbMP
        case .thumbIP: .thumbIP
        case .thumbTip: .thumbTip
        case .indexMCP: .indexMCP
        case .indexPIP: .indexPIP
        case .indexDIP: .indexDIP
        case .indexTip: .indexTip
        case .middleMCP: .middleMCP
        case .middlePIP: .middlePIP
        case .middleDIP: .middleDIP
        case .middleTip: .middleTip
        case .ringMCP: .ringMCP
        case .ringPIP: .ringPIP
        case .ringDIP: .ringDIP
        case .ringTip: .ringTip
        case .littleMCP: .littleMCP
        case .littlePIP: .littlePIP
        case .littleDIP: .littleDIP
        case .littleTip: .littleTip
        }
    }
}

private extension BodyJoint {
    var visionName: HumanBodyPoseObservation.JointName {
        switch self {
        case .nose: .nose
        case .neck: .neck
        case .leftShoulder: .leftShoulder
        case .rightShoulder: .rightShoulder
        case .leftElbow: .leftElbow
        case .rightElbow: .rightElbow
        case .leftWrist: .leftWrist
        case .rightWrist: .rightWrist
        }
    }
}
