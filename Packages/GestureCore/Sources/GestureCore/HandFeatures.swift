// Pose geometry adapted from Pawvis (MIT, © 2026 Alexandria Redmon), Sources/PawvisCore/Hands/HandFeatures.swift:
// the PIP-angle extension bands, the openness measure and its calibration, the knuckle-span scale fallback
// and the wrist–middle-knuckle anchor. See THIRD_PARTY_NOTICES.md.

import Foundation

public enum Finger: Int, CaseIterable, Codable, Sendable {
    case index, middle, ring, little

    public var mcp: HandJoint { [HandJoint.indexMCP, .middleMCP, .ringMCP, .littleMCP][rawValue] }
    public var pip: HandJoint { [HandJoint.indexPIP, .middlePIP, .ringPIP, .littlePIP][rawValue] }
    public var tip: HandJoint { [HandJoint.indexTip, .middleTip, .ringTip, .littleTip][rawValue] }
}

public struct PoseThresholds: Codable, Equatable, Sendable {
    /// A finger is extended when its PIP angle (knuckle–PIP–tip) exceeds this, in radians (π = straight).
    public var extendedAngle = 2.15
    /// A finger is curled below this; between the two it is neutral and neither pose claims it.
    public var curledAngle = 1.75
    /// The thumb is extended when thumbTip→indexMCP exceeds this many hand sizes.
    public var thumbExtendedRatio = 0.50
    /// An open hand also needs this much openness: angle bands alone can't see fingers curled toward the camera.
    public var openHandMinOpenness = 0.29
    /// At or below this openness, with no finger extended, the hand reads as closed.
    public var closedHandMaxOpenness = 0.15
    /// A closed hand is a fist only with the index tucked shorter than this (hand sizes). Recorded fists tuck it to
    /// 0.18–0.42; a pinch keeps it out at the thumb.
    public var fistMaxIndexReach = 0.45

    public init() {}
}

/// Scale-normalized geometry for one hand. Ratios are in hand sizes (wrist→middle knuckle);
/// positions are in image-height units, like `HandFrame`'s subscript.
public struct HandFeatures: Sendable {
    public let hand: HandFrame
    public let scale: Double
    public let thresholds: PoseThresholds

    public init?(_ hand: HandFrame, thresholds: PoseThresholds = PoseThresholds()) {
        if let size = hand.handSize {
            scale = size
        } else if let index = hand[.indexMCP], let little = hand[.littleMCP], index.distance(to: little) > 1e-6 {
            // The knuckle span is about 0.7 hand sizes and survives an occluded wrist.
            scale = index.distance(to: little) / 0.7
        } else {
            return nil
        }
        self.hand = hand
        self.thresholds = thresholds
    }

    public func pipAngle(_ finger: Finger) -> Double? {
        guard let mcp = hand[finger.mcp], let pip = hand[finger.pip], let tip = hand[finger.tip] else { return nil }
        return Vec2.angle(at: pip, from: mcp, to: tip)
    }

    public func isExtended(_ finger: Finger) -> Bool? {
        pipAngle(finger).map { $0 > thresholds.extendedAngle }
    }

    public func isCurled(_ finger: Finger) -> Bool? {
        pipAngle(finger).map { $0 < thresholds.curledAngle }
    }

    public var isThumbExtended: Bool? {
        guard let tip = hand[.thumbTip], let indexMCP = hand[.indexMCP] else { return nil }
        return tip.distance(to: indexMCP) / scale > thresholds.thumbExtendedRatio
    }

    /// Mean of the wrist and the four knuckles; needs at least three of them.
    public var palmCenter: Vec2? {
        let points = [HandJoint.wrist, .indexMCP, .middleMCP, .ringMCP, .littleMCP].compactMap { hand[$0] }
        guard points.count >= 3 else { return nil }
        return points.reduce(.zero, +) / Double(points.count)
    }

    /// Wrist–middle-knuckle midpoint: what swipes, pinch travel and the cursor follow. Its joints are fixed,
    /// so it doesn't jump the way a centroid does when some other joint drops below the confidence floor.
    public var anchor: Vec2? {
        guard let wrist = hand[.wrist], let middleMCP = hand[.middleMCP] else { return nil }
        return wrist.midpoint(with: middleMCP)
    }

    /// 0 ≈ fist, 1 ≈ open palm: mean fingertip→palm distance, calibrated fist 0.75 and open 1.55 hand sizes.
    public var openness: Double? {
        guard let palm = palmCenter else { return nil }
        let tips = Finger.allCases.compactMap { hand[$0.tip] }
        guard tips.count == 4 else { return nil }
        let mean = tips.reduce(0) { $0 + $1.distance(to: palm) } / 4 / scale
        return min(max((mean - 0.75) / (1.55 - 0.75), 0), 1)
    }

    /// Four fingers extended and standing off the palm; the thumb is ignored.
    public var isOpenHand: Bool {
        guard Finger.allCases.allSatisfy({ isExtended($0) == true }), let openness else { return false }
        return openness >= thresholds.openHandMinOpenness
    }

    /// Every finger curled, or fingertips collapsed onto the palm with none extended.
    public var isClosedHand: Bool {
        if Finger.allCases.allSatisfy({ isCurled($0) == true }) { return true }
        guard let openness, openness <= thresholds.closedHandMaxOpenness else { return false }
        return Finger.allCases.allSatisfy { isExtended($0) != true }
    }

    /// Fingertip → own knuckle, in hand sizes: about 0.8–1.1 straight, 0.2–0.5 folded. Unlike the PIP angle it also
    /// shortens when a finger bends toward the camera, which is how a tap looks from the front.
    public func reach(_ finger: Finger) -> Double? {
        guard let tip = hand[finger.tip], let mcp = hand[finger.mcp] else { return nil }
        return tip.distance(to: mcp) / scale
    }

    /// Index knuckle → little knuckle, in image heights. Steadier than the wrist-based hand size: in a recorded fast
    /// move the hand size jumped 30% between frames while the knuckle span held within 10%.
    public var knuckleSpan: Double? {
        guard let index = hand[.indexMCP], let little = hand[.littleMCP] else { return nil }
        return index.distance(to: little)
    }

    /// Fingertip → own knuckle measured along the palm (wrist → middle knuckle), in knuckle spans. It shortens like
    /// `reach` when the finger bends toward the camera, and further when the bend also tips it sideways, as the
    /// recorded bends did.
    public func reachAlongPalm(_ finger: Finger) -> Double? {
        guard let tip = hand[finger.tip], let mcp = hand[finger.mcp],
              let wrist = hand[.wrist], let middleMCP = hand[.middleMCP], let span = knuckleSpan, span > 1e-6
        else { return nil }
        let axis = middleMCP - wrist
        guard axis.length > 1e-9 else { return nil }
        return ((tip.x - mcp.x) * axis.x + (tip.y - mcp.y) * axis.y) / axis.length / span
    }

    /// A closed hand with the index tucked into the palm, so a held pinch-drag never reads as one.
    public var isFist: Bool {
        guard isClosedHand, let reach = reach(.index) else { return false }
        return reach < thresholds.fistMaxIndexReach
    }

    /// Thumb tip → index tip, in hand sizes.
    public var pinchRatio: Double? {
        guard let thumb = hand[.thumbTip], let index = hand[.indexTip] else { return nil }
        return thumb.distance(to: index) / scale
    }

    /// Whether the palm, rather than the back, faces the camera. In the un-mirrored image a right hand shows
    /// its palm when the index knuckle is image-right of the little knuckle (wrist-relative cross product > 0);
    /// a left hand is the reverse. Rotation doesn't change the sign. Nil without chirality or joints.
    public var palmFacesCamera: Bool? {
        guard hand.chirality != .unknown,
              let wrist = hand[.wrist], let index = hand[.indexMCP], let little = hand[.littleMCP]
        else { return nil }
        let cross = (index - wrist).cross(little - wrist)
        guard abs(cross) > 1e-9 else { return nil }
        return hand.chirality == .right ? cross > 0 : cross < 0
    }

    /// Thumb standing well clear above the palm, as in a thumbs-up.
    public var thumbPointsUp: Bool {
        guard let palm = palmCenter, let thumb = hand[.thumbTip] else { return false }
        let offset = (thumb - palm) / scale
        return offset.length >= 0.85 && offset.y > 0 && offset.y >= 1.5 * abs(offset.x)
    }

    /// Thumb, index, middle, ring, little — for the debug preview.
    public var extendedFingers: [Bool] {
        [isThumbExtended == true] + Finger.allCases.map { isExtended($0) == true }
    }
}
