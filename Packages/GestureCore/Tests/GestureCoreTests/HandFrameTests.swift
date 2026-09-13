import Foundation
import Testing
@testable import GestureCore

struct HandFrameTests {
    private func hand(_ points: [HandJoint: Vec2], confidence: Double = 0.9, aspect: Double = 2.0) -> HandFrame {
        HandFrame(
            joints: points.mapValues { JointPoint(position: $0, confidence: confidence) },
            chirality: .right,
            timestamp: 0,
            imageAspect: aspect
        )
    }

    @Test func handSizeIsWristToMiddleMCPDistance() throws {
        let frame = hand([.wrist: Vec2(0.5, 0.2), .middleMCP: Vec2(0.5, 0.35)])
        let size = try #require(frame.handSize)
        #expect(abs(size - 0.15) < 1e-9)
    }

    @Test func geometryScalesXByImageAspect() {
        let frame = hand([.indexTip: Vec2(0.3, 0.4)], aspect: 2.0)
        #expect(frame.normalizedPosition(of: .indexTip) == Vec2(0.3, 0.4))
        #expect(frame[.indexTip] == Vec2(0.6, 0.4))
    }

    @Test func lowConfidenceJointsReadAsMissing() {
        let frame = hand([.wrist: Vec2(0.5, 0.2), .middleMCP: Vec2(0.5, 0.35)], confidence: 0.1)
        #expect(frame[.wrist] == nil)
        #expect(frame.handSize == nil)
    }

    @Test func codableRoundTrip() throws {
        let frame = hand([.wrist: Vec2(0.1, 0.2), .indexTip: Vec2(0.3, 0.4)])
        let data = try JSONEncoder().encode(frame)
        let decoded = try JSONDecoder().decode(HandFrame.self, from: data)
        #expect(decoded.normalizedPosition(of: .indexTip) == Vec2(0.3, 0.4))
        #expect(decoded[.thumbTip] == nil)
        #expect(decoded.chirality == .right)
        #expect(decoded.imageAspect == 2.0)
    }
}
