import Foundation

/// Ties standalone hand detections to body-pose people (HandSource mode B).
/// The hand-box geometry uses OpenPose's published numbers (`handDetector.cpp`); no OpenPose code is used.
public enum HandAssociation {
    public struct HandBox: Sendable, Equatable {
        public var center: Vec2
        public var side: Double

        public func contains(_ point: Vec2) -> Bool {
            abs(point.x - center.x) <= side / 2 && abs(point.y - center.y) <= side / 2
        }
    }

    /// Square box where a hand should be, extrapolated from the forearm. All inputs in image-height units.
    public static func handBox(wrist: Vec2, elbow: Vec2, shoulder: Vec2?) -> HandBox {
        let forearm = wrist - elbow
        let upperArm = shoulder.map { elbow.distance(to: $0) } ?? 0
        return HandBox(center: wrist + forearm * 0.33, side: 1.5 * max(forearm.length, 0.9 * upperArm))
    }

    /// Attaches each hand to at most one body side, nearest wrist first. A hand whose own chirality
    /// disagrees with the side still attaches, but only after same-side matches (Vision's chirality can be wrong).
    public static func attach(_ hands: [HandFrame], to bodies: [Body]) -> (bodies: [Body], looseHands: [HandFrame]) {
        struct Slot: Hashable {
            let body: Int
            let side: Chirality
        }
        struct Candidate {
            let hand: Int
            let slot: Slot
            let cost: Double
        }

        var candidates: [Candidate] = []
        for (handIndex, hand) in hands.enumerated() {
            guard let wrist = hand[.wrist] else { continue }
            for (bodyIndex, body) in bodies.enumerated() {
                for side in [Chirality.left, .right] {
                    guard let bodyWrist = body.wrist(side), let elbow = body.elbow(side) else { continue }
                    let box = handBox(wrist: bodyWrist, elbow: elbow, shoulder: body.shoulder(side))
                    guard box.contains(wrist) else { continue }
                    let mismatch = hand.chirality != .unknown && hand.chirality != side
                    let distance = wrist.distance(to: bodyWrist)
                    candidates.append(Candidate(hand: handIndex, slot: Slot(body: bodyIndex, side: side), cost: mismatch ? distance + 10 : distance))
                }
            }
        }

        var result = bodies
        var usedHands = Set<Int>()
        var usedSlots = Set<Slot>()
        for candidate in candidates.sorted(by: { $0.cost < $1.cost }) {
            guard !usedHands.contains(candidate.hand), !usedSlots.contains(candidate.slot) else { continue }
            usedHands.insert(candidate.hand)
            usedSlots.insert(candidate.slot)
            var hand = hands[candidate.hand]
            hand.chirality = candidate.slot.side
            if candidate.slot.side == .left {
                result[candidate.slot.body].leftHand = hand
            } else {
                result[candidate.slot.body].rightHand = hand
            }
        }
        let loose = hands.indices.filter { !usedHands.contains($0) }.map { hands[$0] }
        return (result, loose)
    }
}
