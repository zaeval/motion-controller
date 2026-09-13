import Foundation
import Testing
@testable import GestureCore

struct HandAssociationTests {
    private func point(_ x: Double, _ y: Double) -> JointPoint {
        JointPoint(position: Vec2(x, y), confidence: 0.9)
    }

    /// A person centred at `x` with both forearms raised.
    private func body(at x: Double) -> Body {
        Body(
            joints: [
                .leftShoulder: point(x + 0.1, 0.5), .rightShoulder: point(x - 0.1, 0.5),
                .leftElbow: point(x + 0.15, 0.4), .rightElbow: point(x - 0.15, 0.4),
                .leftWrist: point(x + 0.15, 0.55), .rightWrist: point(x - 0.15, 0.55),
            ],
            timestamp: 0,
            imageAspect: 1
        )
    }

    private func hand(wristAt x: Double, _ y: Double, chirality: Chirality = .unknown) -> HandFrame {
        HandFrame(joints: [.wrist: point(x, y)], chirality: chirality, timestamp: 0, imageAspect: 1)
    }

    @Test func handsAttachToTheNearestWristOfTheRightPerson() {
        let people = [body(at: 0.3), body(at: 0.7)]
        let hands = [hand(wristAt: 0.86, 0.57), hand(wristAt: 0.16, 0.56)]

        let result = HandAssociation.attach(hands, to: people)

        #expect(result.looseHands.isEmpty)
        #expect(result.bodies[1].leftHand?.normalizedPosition(of: .wrist) == Vec2(0.86, 0.57))
        #expect(result.bodies[0].rightHand?.normalizedPosition(of: .wrist) == Vec2(0.16, 0.56))
        #expect(result.bodies[0].leftHand == nil)
        #expect(result.bodies[1].rightHand == nil)
    }

    @Test func handFarFromEveryWristStaysLoose() {
        let result = HandAssociation.attach([hand(wristAt: 0.5, 0.05)], to: [body(at: 0.3)])
        #expect(result.looseHands.count == 1)
        #expect(result.bodies[0].hands.isEmpty)
    }

    @Test func attachedHandTakesTheBodySideAsChirality() {
        let result = HandAssociation.attach([hand(wristAt: 0.45, 0.56, chirality: .right)], to: [body(at: 0.3)])
        #expect(result.bodies[0].leftHand?.chirality == .left)
    }

    @Test func chiralityBreaksTiesWhenBothSidesFit() {
        // Wrists 0.1 apart, so one hand sits inside both boxes; its chirality should decide.
        var narrow = body(at: 0.5)
        narrow.joints[BodyJoint.leftWrist.rawValue] = point(0.55, 0.55)
        narrow.joints[BodyJoint.rightWrist.rawValue] = point(0.45, 0.55)
        let result = HandAssociation.attach([hand(wristAt: 0.49, 0.55, chirality: .left)], to: [narrow])
        #expect(result.bodies[0].leftHand != nil)
        #expect(result.bodies[0].rightHand == nil)
    }
}
