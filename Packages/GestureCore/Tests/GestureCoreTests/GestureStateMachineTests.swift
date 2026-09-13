import Foundation
import Testing
@testable import GestureCore

struct GestureStateMachineTests {
    private static let frame = 1.0 / 30

    /// Feeds `count` frames starting at `start`; returns the times at which the pose fired.
    private func run(
        _ machine: inout GestureStateMachine,
        from start: TimeInterval,
        frames count: Int,
        detected: Bool = true,
        still: Bool = true
    ) -> [TimeInterval] {
        var fired: [TimeInterval] = []
        for index in 0..<count {
            let time = start + Double(index) * Self.frame
            if machine.update(detected: detected, handStill: still, at: time) { fired.append(time) }
        }
        return fired
    }

    @Test func firesOnceAfterConfirmFramesAndHold() {
        var machine = GestureStateMachine(timing: .init(candidateFrames: 4, holdSeconds: 0.4, cooldownSeconds: 0.8))
        let fired = run(&machine, from: 0, frames: 30)
        #expect(fired.count == 1)
        // 4 confirm frames put arming at frame 3 (0.1 s); the hold ends 0.4 s later.
        #expect(abs((fired.first ?? 0) - 0.5) < Self.frame + 1e-9)
    }

    @Test func releasingBeforeTheHoldEndsDoesNotFire() {
        var machine = GestureStateMachine(timing: .init(holdSeconds: 0.4))
        #expect(run(&machine, from: 0, frames: 10).isEmpty)
        #expect(run(&machine, from: 10 * Self.frame, frames: 1, detected: false).isEmpty)
        #expect(machine.phase == .idle)
    }

    @Test func movingHandRestartsTheHold() {
        var machine = GestureStateMachine(timing: .init(candidateFrames: 1, holdSeconds: 0.4))
        #expect(run(&machine, from: 0, frames: 10).isEmpty)
        #expect(run(&machine, from: 10 * Self.frame, frames: 10, still: false).isEmpty)
        #expect(machine.holdProgress(at: 20 * Self.frame) < 0.1)
    }

    @Test func mustReleaseAndWaitOutCooldownBeforeFiringAgain() {
        var machine = GestureStateMachine(timing: .init(candidateFrames: 1, holdSeconds: 0.1, cooldownSeconds: 0.5))
        #expect(run(&machine, from: 0, frames: 60).count == 1)
        #expect(machine.phase == .waitingForRelease)
        #expect(run(&machine, from: 2.0, frames: 1, detected: false).isEmpty)
        #expect(run(&machine, from: 2.1, frames: 10).count == 1)
    }

    @Test func repeatingPoseFiresWhileHeld() {
        var machine = GestureStateMachine(timing: .init(candidateFrames: 1, holdSeconds: 0.3, repeatSeconds: 0.2))
        let fired = run(&machine, from: 0, frames: 30)
        // First fire at 0.3 s, then roughly every 0.2 s until 1.0 s.
        #expect(fired.count == 4)
    }
}
