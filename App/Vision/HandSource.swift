import CoreVideo
import Foundation
import GestureCore
import os
import Vision

enum HandSourceMode: String, CaseIterable, Identifiable, Sendable {
    /// (A) One body-pose request with `detectsHands`; hands arrive already attached to people. Cheaper, but a hand
    /// only exists as part of a person: hold it in front of your own face or chest and the body observation goes,
    /// taking the hand with it. That is why it is no longer the default — the user, 2026-09-14: "몸이나 얼굴 가릴때마다
    /// 검지가 풀린다".
    case bodyWithHands
    /// (B) Hand pose every frame plus body pose at 10 fps, attached by wrist boxes. The hand request doesn't need to
    /// see a body, so a hand over the face keeps tracking; one that matches no body arrives as a loose hand, which
    /// `PoseFrame.allHands` includes. Chirality comes from Vision's own `chirality` rather than from which arm it
    /// hangs off.
    case handsPlusBody

    var id: String { rawValue }
}

/// Runs Vision on camera frames. One frame is in flight at a time and frames that arrive
/// while busy are dropped, so detection always works on the newest image.
///
/// **Cropping around the hand doesn't work; don't try it again.** A small hand is what the hand request misses — the
/// user's pointing hand at 0.15 of the frame's height was lost on 35–40% of frames, their palm at 0.26 on none — so
/// giving Vision less to look at and more hand in it is the obvious fix. Measured on 2026-09-15, one frame, same
/// buffer, hand plainly inside the region:
///
/// | what | found | cost |
/// |---|---|---|
/// | whole frame | the hand, size 0.255 | 28.8 ms |
/// | `regionOfInterest` as given | **nothing** | 21.1 ms |
/// | `regionOfInterest`, vertical origin flipped | **nothing** | 18.5 ms |
/// | `CIImage.cropped(to:)`, region cut out for real | the hand | **271.5 ms** |
///
/// So the region of interest doesn't narrow this request's search, it stops it finding anything, and an actually cut
/// image costs ten times the whole frame (and came back in coordinates that matched neither the crop nor the image).
/// Raising the capture resolution was tried too: 1920×1080 at 30 fps exists on this camera and took Vision from
/// 20 ms to 79 ms. What is left is a bigger hand in front of the camera.
final class HandSource: Sendable {
    struct Output: Sendable {
        let frame: PoseFrame
        let processingMilliseconds: Double
        /// What each Vision request cost on this frame, to see where the frame rate goes; the body one is 0 on the
        /// frames it doesn't run.
        let handMilliseconds: Double
        let bodyMilliseconds: Double
        /// Set when Vision threw on this frame (the frame is then empty), so "no hands" and "failing" differ.
        let error: String?
    }

    private struct State: Sendable {
        var mode: HandSourceMode = .handsPlusBody
        var busy = false
        var cachedBodies: [Body] = []
        var cachedBodiesTime: TimeInterval = -.infinity
        var handler: (@Sendable (Output) -> Void)?
    }

    private static let bodyRefreshInterval: TimeInterval = 0.1
    /// While a hand is in view the body pose is worth far less — the hand itself proves somebody is there, and the
    /// cursor follows the hand, not the body — and it is the expensive request: 47.7 ms against the hand's 23.8, on
    /// 48% of frames, which is where the frame rate was going (measured 2026-09-16). So it runs a quarter as often
    /// while a hand is tracked, and at full rate again the moment the hand is gone.
    private static let bodyRefreshWithHand: TimeInterval = 0.4
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
            var handMilliseconds = 0.0
            var bodyMilliseconds = 0.0
            var failure: String?
            do {
                let detected = try await self.detect(mode: mode, in: buffer, aspect: aspect, at: time)
                frame = detected.frame
                handMilliseconds = detected.hand
                bodyMilliseconds = detected.body
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
            handler?(Output(
                frame: frame, processingMilliseconds: elapsed.milliseconds,
                handMilliseconds: handMilliseconds, bodyMilliseconds: bodyMilliseconds, error: failure
            ))
        }
    }

    private func detect(
        mode: HandSourceMode, in buffer: CVPixelBuffer, aspect: Double, at time: TimeInterval
    ) async throws -> (frame: PoseFrame, hand: Double, body: Double) {
        switch mode {
        case .bodyWithHands:
            var request = DetectHumanBodyPoseRequest()
            request.detectsHands = true
            let clock = ContinuousClock()
            let started = clock.now
            let bodies = try await request.perform(on: buffer).map {
                VisionMapping.body(from: $0, aspect: aspect, at: time, includeHands: true)
            }
            let frame = PoseFrame(bodies: bodies, looseHands: [], timestamp: time, imageAspect: aspect)
            return (frame, 0, started.duration(to: clock.now).milliseconds)

        case .handsPlusBody:
            var handRequest = DetectHumanHandPoseRequest()
            // Two: one operator, two hands. Four cost frame rate for people this app doesn't act on anyway — the
            // operator lock that would need them is v2.
            handRequest.maximumHandCount = 2
            let clock = ContinuousClock()
            let handStarted = clock.now
            let hands = try await handRequest.perform(on: buffer).map {
                VisionMapping.hand(from: $0, side: nil, aspect: aspect, at: time)
            }
            let handMilliseconds = handStarted.duration(to: clock.now).milliseconds
            let refresh = hands.isEmpty ? Self.bodyRefreshInterval : Self.bodyRefreshWithHand
            let needsBodies = state.withLock { time - $0.cachedBodiesTime >= refresh }
            let bodies: [Body]
            var bodyMilliseconds = 0.0
            if needsBodies {
                let bodyStarted = clock.now
                bodies = try await DetectHumanBodyPoseRequest().perform(on: buffer).map {
                    VisionMapping.body(from: $0, aspect: aspect, at: time, includeHands: false)
                }
                bodyMilliseconds = bodyStarted.duration(to: clock.now).milliseconds
                state.withLock {
                    $0.cachedBodies = bodies
                    $0.cachedBodiesTime = time
                }
            } else {
                bodies = state.withLock { $0.cachedBodies }
            }
            let attached = HandAssociation.attach(hands, to: bodies)
            let frame = PoseFrame(bodies: attached.bodies, looseHands: attached.looseHands, timestamp: time, imageAspect: aspect)
            return (frame, handMilliseconds, bodyMilliseconds)
        }
    }
}

private extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
