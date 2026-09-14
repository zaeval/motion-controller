import Foundation
import Testing
@testable import GestureCore

struct ZoomControlTests {
    private static let frame = 1.0 / 30
    /// With this hand size a stride of 0.25 hand sizes is 0.05 of the frame.
    private static let size = 0.2

    /// Feeds one frame per height, nil for a frame without three fingers, and returns the steps that fired.
    private func steps(_ zoom: inout ZoomControl, _ heights: [Double?]) -> [Int] {
        heights.enumerated().compactMap { index, height in
            let step = zoom.update(
                active: height != nil, anchor: height.map { Vec2(0.5, $0) }, handSize: Self.size,
                at: Double(index) * Self.frame
            )
            return step == 0 ? nil : step
        }
    }

    private static func held(_ height: Double, frames: Int) -> [Double?] {
        Array(repeating: height, count: frames)
    }

    private static func ramp(_ from: Double, _ to: Double, frames: Int) -> [Double?] {
        (1...frames).map { from + (to - from) * Double($0) / Double(frames) }
    }

    @Test func raisingZoomsInAndLoweringZoomsOutOneStepPerStride() {
        var zoom = ZoomControl()
        // 0.02 a frame: a stride completes every third frame, as often as steps may come.
        let frames = Self.held(0.4, frames: 6) + Self.ramp(0.4, 0.6, frames: 10) + Self.ramp(0.6, 0.4, frames: 10)
        #expect(steps(&zoom, frames) == [1, 1, 1, -1, -1, -1])
    }

    @Test func aFastStrokeStepsOnlyAsOftenAsTheIntervalAndDropsTheRest() {
        var zoom = ZoomControl()
        // 0.4 up in four frames is eight strides, but it steps on the first frame and again three frames later.
        let frames = Self.held(0.4, frames: 6) + [0.5, 0.6, 0.7, 0.8] + Self.held(0.8, frames: 15)
        #expect(steps(&zoom, frames) == [1, 1])
    }

    @Test func aTrackingJumpStartsOverInsteadOfZooming() {
        var zoom = ZoomControl()
        let frames = Self.held(0.4, frames: 6) + Self.held(0.7, frames: 4) + Self.ramp(0.7, 0.8, frames: 5)
        #expect(steps(&zoom, frames) == [1])
    }

    @Test func passingThroughThePoseOrLettingGoNeverZooms() {
        var zoom = ZoomControl()
        // Three frames of three fingers on the way to a fist, moving fast: not engaged yet.
        #expect(steps(&zoom, [0.4, 0.5, 0.6, nil]).isEmpty)
        // Letting go forgets where the hand was: it engages again from where it comes back.
        #expect(steps(&zoom, Self.held(0.4, frames: 6) + [nil, 0.45, 0.5, 0.5, 0.5, 0.5]).isEmpty)
    }
}
