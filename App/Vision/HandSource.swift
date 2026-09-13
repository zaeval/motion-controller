import CoreVideo
import Foundation
import GestureCore
import os
import Vision

enum HandSourceMode: String, CaseIterable, Identifiable, Sendable {
    /// (A) One body-pose request with `detectsHands`; hands arrive already attached to people.
    case bodyWithHands
    /// (B) Hand pose every frame plus body pose at 10 fps, attached by wrist boxes.
    case handsPlusBody

    var id: String { rawValue }
}

/// Runs Vision on camera frames. One frame is in flight at a time and frames that arrive
/// while busy are dropped, so detection always works on the newest image.
final class HandSource: Sendable {
    struct Output: Sendable {
        let frame: PoseFrame
        let processingMilliseconds: Double
        /// Set when Vision threw on this frame (the frame is then empty), so "no hands" and "failing" differ.
        let error: String?
    }

    private struct State: Sendable {
        var mode: HandSourceMode = .bodyWithHands
        var busy = false
        var cachedBodies: [Body] = []
        var cachedBodiesTime: TimeInterval = -.infinity
        var handler: (@Sendable (Output) -> Void)?
    }

    private static let bodyRefreshInterval: TimeInterval = 0.1
    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "HandSource")
    private let state = OSAllocatedUnfairLock(initialState: State())

    var mode: HandSourceMode {
        get { state.withLock { $0.mode } }
        set {
            state.withLock {
                $0.mode = newValue
                $0.cachedBodies = []
                $0.cachedBodiesTime = -.infinity
            }
        }
    }

    func setHandler(_ handler: @escaping @Sendable (Output) -> Void) {
        state.withLock { $0.handler = handler }
    }

    func process(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        let mode: HandSourceMode? = state.withLock {
            guard !$0.busy else { return nil }
            $0.busy = true
            return $0.mode
        }
        guard let mode else { return }

        nonisolated(unsafe) let buffer = pixelBuffer
        let aspect = Double(CVPixelBufferGetWidth(pixelBuffer)) / Double(max(CVPixelBufferGetHeight(pixelBuffer), 1))
        Task.detached(priority: .userInitiated) {
            let clock = ContinuousClock()
            let start = clock.now
            let frame: PoseFrame
            var failure: String?
            do {
                frame = try await self.detect(mode: mode, in: buffer, aspect: aspect, at: time)
            } catch {
                Self.logger.error("Vision \(mode.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
                failure = "\(mode.rawValue): \(error.localizedDescription)"
                frame = PoseFrame(bodies: [], looseHands: [], timestamp: time, imageAspect: aspect)
            }
            let elapsed = start.duration(to: clock.now)
            let handler = self.state.withLock {
                $0.busy = false
                return $0.handler
            }
            handler?(Output(frame: frame, processingMilliseconds: elapsed.milliseconds, error: failure))
        }
    }

    private func detect(mode: HandSourceMode, in buffer: CVPixelBuffer, aspect: Double, at time: TimeInterval) async throws -> PoseFrame {
        switch mode {
        case .bodyWithHands:
            var request = DetectHumanBodyPoseRequest()
            request.detectsHands = true
            let bodies = try await request.perform(on: buffer).map {
                VisionMapping.body(from: $0, aspect: aspect, at: time, includeHands: true)
            }
            return PoseFrame(bodies: bodies, looseHands: [], timestamp: time, imageAspect: aspect)

        case .handsPlusBody:
            var handRequest = DetectHumanHandPoseRequest()
            handRequest.maximumHandCount = 4
            let hands = try await handRequest.perform(on: buffer).map {
                VisionMapping.hand(from: $0, side: nil, aspect: aspect, at: time)
            }
            let needsBodies = state.withLock { time - $0.cachedBodiesTime >= Self.bodyRefreshInterval }
            let bodies: [Body]
            if needsBodies {
                bodies = try await DetectHumanBodyPoseRequest().perform(on: buffer).map {
                    VisionMapping.body(from: $0, aspect: aspect, at: time, includeHands: false)
                }
                state.withLock {
                    $0.cachedBodies = bodies
                    $0.cachedBodiesTime = time
                }
            } else {
                bodies = state.withLock { $0.cachedBodies }
            }
            let attached = HandAssociation.attach(hands, to: bodies)
            return PoseFrame(bodies: attached.bodies, looseHands: attached.looseHands, timestamp: time, imageAspect: aspect)
        }
    }
}

private extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
