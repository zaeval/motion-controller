import Foundation
@testable import GestureCore

/// Idealized 2D hands for rule tests. Geometry is laid out in hand sizes around the wrist (y up), with the
/// index side on +x for a right hand showing its palm to the un-mirrored camera; image aspect is 1.
enum SyntheticHand {
    enum Thumb {
        case extended, curled, up
    }

    struct Shape {
        var thumb = Thumb.extended
        var index = true
        var middle = true
        var ring = true
        var little = true
        var palmTowardCamera = true
        var pinch = false
    }

    static func make(
        _ shape: Shape,
        chirality: Chirality = .right,
        wrist: Vec2 = Vec2(0.5, 0.5),
        size: Double = 0.15,
        time: TimeInterval = 0
    ) -> HandFrame {
        // Mirroring the layout is the same as turning the hand around or swapping hands.
        let side: Double = (chirality == .right) == shape.palmTowardCamera ? 1 : -1
        var local: [HandJoint: Vec2] = [.wrist: .zero]

        let fingers: [(mcp: HandJoint, pip: HandJoint, dip: HandJoint, tip: HandJoint, knuckle: Vec2, extended: Bool)] = [
            (.indexMCP, .indexPIP, .indexDIP, .indexTip, Vec2(0.28, 0.95), shape.index),
            (.middleMCP, .middlePIP, .middleDIP, .middleTip, Vec2(0.0, 1.0), shape.middle),
            (.ringMCP, .ringPIP, .ringDIP, .ringTip, Vec2(-0.24, 0.96), shape.ring),
            (.littleMCP, .littlePIP, .littleDIP, .littleTip, Vec2(-0.45, 0.85), shape.little),
        ]
        for finger in fingers {
            let knuckle = finger.knuckle
            local[finger.mcp] = knuckle
            if finger.extended {
                let spread = knuckle.x * 0.15
                local[finger.pip] = knuckle + Vec2(spread, 0.45)
                local[finger.dip] = knuckle + Vec2(spread * 1.6, 0.73)
                local[finger.tip] = knuckle + Vec2(spread * 2.0, 0.95)
            } else {
                local[finger.pip] = knuckle + Vec2(0, 0.38)
                local[finger.dip] = knuckle + Vec2(0.02, 0.22)
                local[finger.tip] = knuckle + Vec2(0.03, 0.10)
            }
        }

        switch shape.thumb {
        case .extended:
            local[.thumbCMC] = Vec2(0.25, 0.25)
            local[.thumbMP] = Vec2(0.50, 0.45)
            local[.thumbIP] = Vec2(0.68, 0.62)
            local[.thumbTip] = Vec2(0.85, 0.78)
        case .curled:
            local[.thumbCMC] = Vec2(0.25, 0.25)
            local[.thumbMP] = Vec2(0.35, 0.45)
            local[.thumbIP] = Vec2(0.30, 0.62)
            local[.thumbTip] = Vec2(0.12, 0.70)
        case .up:
            local[.thumbCMC] = Vec2(0.25, 0.30)
            local[.thumbMP] = Vec2(0.30, 0.70)
            local[.thumbIP] = Vec2(0.30, 1.20)
            local[.thumbTip] = Vec2(0.30, 1.75)
        }
        if shape.pinch, let indexTip = local[.indexTip] {
            local[.thumbTip] = indexTip + Vec2(-0.03, -0.02)
        }

        let joints = local.mapValues { point in
            JointPoint(position: Vec2(wrist.x + side * point.x * size, wrist.y + point.y * size), confidence: 0.9)
        }
        return HandFrame(joints: joints, chirality: chirality, timestamp: time, imageAspect: 1)
    }
}
