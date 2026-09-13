import Foundation
import Testing
@testable import GestureCore

struct BodyTests {
    @Test func intersectionOverUnion() {
        let a = BoundingBox(minX: 0, minY: 0, maxX: 2, maxY: 2)
        #expect(a.intersectionOverUnion(with: a) == 1)
        #expect(a.intersectionOverUnion(with: BoundingBox(minX: 3, minY: 3, maxX: 4, maxY: 4)) == 0)
        // Overlap 1×2 = 2, union 4 + 4 − 2 = 6.
        let shifted = BoundingBox(minX: 1, minY: 0, maxX: 3, maxY: 2)
        #expect(abs(a.intersectionOverUnion(with: shifted) - 2.0 / 6.0) < 1e-12)
    }

    @Test func shoulderWidthAndBoxUseImageHeightUnits() throws {
        let body = Body(
            joints: [
                .leftShoulder: JointPoint(position: Vec2(0.6, 0.6), confidence: 0.9),
                .rightShoulder: JointPoint(position: Vec2(0.4, 0.6), confidence: 0.9),
                .nose: JointPoint(position: Vec2(0.5, 0.8), confidence: 0.9),
            ],
            timestamp: 0,
            imageAspect: 2.0
        )
        let width = try #require(body.shoulderWidth)
        #expect(abs(width - 0.4) < 1e-12)
        let box = try #require(body.boundingBox)
        #expect(abs(box.minX - 0.8) < 1e-12)
        #expect(abs(box.maxX - 1.2) < 1e-12)
        #expect(box.maxY == 0.8)
    }
}
