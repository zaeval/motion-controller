import CoreGraphics
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
final class HandSource: Sendable {
    struct Output: Sendable {
        let frame: PoseFrame
        let processingMilliseconds: Double
        /// Set when Vision threw on this frame (the frame is then empty), so "no hands" and "failing" differ.
        let error: String?
    }

    private struct State: Sendable {
        var mode: HandSourceMode = .handsPlusBody
        var busy = false
        var cachedBodies: [Body] = []
        var cachedBodiesTime: TimeInterval = -.infinity
        /// Where the hands were last seen, in image-normalized coordinates (y up), and when: the crop follows them.
        var handBox: CGRect?
        var handBoxTime: TimeInterval = -.infinity
        /// The largest hand of the last whole-frame look, to check a cropped result against.
        var lastFullSize: Double?
        /// Set when a cropped result didn't line up with that size: cropping is abandoned for the rest of the run.
        var cropDistrusted = false
        var loggedCrop = false
        var handler: (@Sendable (Output) -> Void)?
    }

    private static let bodyRefreshInterval: TimeInterval = 0.1
    /// The crop is this much of the hands' own size, so a hand that moved since the last frame is still inside it.
    private static let cropScale = 3.0
    /// ...and never shorter than this share of the frame height: a crop chasing a badly measured hand would lose it.
    private static let minCropHeight = 0.3
    /// Hands older than this are not where the crop thinks they are.
    private static let cropLifetime: TimeInterval = 0.4
    /// A cropped hand must measure within this factor of the last whole-frame hand, or the mapping is wrong and the
    /// crop is abandoned. Vision documents a pose request's points as normalized to the region of interest; this is
    /// what catches it if that ever isn't so, instead of sending the cursor somewhere absurd.
    private static let cropSizeTolerance = 2.0
    /// `MC_CROP=1` looks for the hand in a crop around where it just was; `MC_CROP=probe` runs the crop beside the
    /// whole frame and logs what each one saw, which is how the region's coordinate convention gets settled.
    ///
    /// Off by default because the first attempt cost far more than it saved: the crop pass found nothing and every
    /// frame paid for both passes — 120–150 ms, 6–8 fps (2026-09-15). Until a probe says which way the region and
    /// its results are oriented, whole-frame detection is what runs.
    private static let cropMode = ProcessInfo.processInfo.environment["MC_CROP"]
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
            var hands = Self.cropMode == nil ? [] : try await cropped(buffer, aspect: aspect, at: time)
            if hands.isEmpty {
                // No crop to look in, or the hands have left it: the whole frame, which is also what sets the size a
                // cropped result is checked against.
                hands = try await wholeFrame(buffer, aspect: aspect, at: time)
                let size = hands.compactMap(\.handSize).max()
                state.withLock { $0.lastFullSize = size ?? $0.lastFullSize }
            }
            // Around both hands, because the other hand is the one that clicks: a crop that kept only the cursor hand
            // would hide it.
            let box = Self.box(of: hands)
            state.withLock {
                $0.handBox = box
                if box != nil { $0.handBoxTime = time }
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

extension HandSource {
    /// Runs the hand request on a crop around where the hands just were, when there is one to run on. A small hand
    /// fills much more of a crop than of the frame, and Vision scales whatever it is given into the pose model's
    /// input — that scaling is the whole point. Empty when there is no crop, when the hands have left it, or when the
    /// result doesn't line up with the last whole-frame measurement.
    private func cropped(_ buffer: CVPixelBuffer, aspect: Double, at time: TimeInterval) async throws -> [HandFrame] {
        let crop: CGRect? = state.withLock { state in
            guard !state.cropDistrusted, let box = state.handBox, time - state.handBoxTime <= Self.cropLifetime
            else { return nil }
            return Self.cropRect(around: box, aspect: aspect)
        }
        guard let crop else { return [] }
        if Self.cropMode == "probe" {
            try await probe(buffer, aspect: aspect, at: time, crop: crop)
            return []
        }
        var request = DetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        request.regionOfInterest = NormalizedRect(
            x: crop.minX, y: crop.minY, width: crop.width, height: crop.height
        )
        let hands = try await request.perform(on: buffer).map {
            VisionMapping.hand(from: $0, side: nil, aspect: aspect, at: time, crop: crop)
        }
        guard let size = hands.compactMap(\.handSize).max() else { return [] }
        let expected = state.withLock { $0.lastFullSize }
        if let expected, expected > 0, max(size / expected, expected / size) > Self.cropSizeTolerance {
            state.withLock { $0.cropDistrusted = true }
            Self.logger.error("Cropped hand measured \(size, format: .fixed(precision: 3), privacy: .public) against whole-frame \(expected, format: .fixed(precision: 3), privacy: .public): the region-of-interest mapping is wrong, so cropping is off for this run")
            return []
        }
        let shouldLog = state.withLock { state -> Bool in
            guard !state.loggedCrop else { return false }
            state.loggedCrop = true
            return true
        }
        if shouldLog {
            Self.logger.notice("Cropping to \(crop.width, format: .fixed(precision: 2), privacy: .public)x\(crop.height, format: .fixed(precision: 2), privacy: .public) of the frame; hand measures \(size, format: .fixed(precision: 3), privacy: .public), whole-frame \(expected ?? 0, format: .fixed(precision: 3), privacy: .public)")
        }
        return hands
    }

    /// Runs the region two ways against the whole frame and logs all three, so the region's convention — where its
    /// origin is and what its results are normalized to — comes out of a measurement rather than a guess. One frame
    /// of a hand in view is enough.
    private func probe(_ buffer: CVPixelBuffer, aspect: Double, at time: TimeInterval, crop: CGRect) async throws {
        let logged = state.withLock { state -> Bool in
            guard !state.loggedCrop else { return true }
            state.loggedCrop = true
            return false
        }
        guard !logged else { return }
        func describe(_ hands: [HandFrame]) -> String {
            guard let hand = hands.max(by: { ($0.handSize ?? 0) < ($1.handSize ?? 0) }), let wrist = hand[.wrist]
            else { return "none" }
            return String(format: "n=%d size %.3f wrist (%.2f,%.2f)", hands.count, hand.handSize ?? 0, wrist.x, wrist.y)
        }
        // Timed, because cost decides this as much as coordinates do: the first attempt at cropping ran at 6–8 fps.
        func run(_ region: NormalizedRect?) async throws -> (hands: [HandFrame], milliseconds: Double) {
            var request = DetectHumanHandPoseRequest()
            request.maximumHandCount = 2
            // Left alone for the whole-frame run: the property is not optional, and its default is the whole frame.
            if let region { request.regionOfInterest = region }
            let clock = ContinuousClock()
            let start = clock.now
            let hands = try await request.perform(on: buffer).map {
                VisionMapping.hand(from: $0, side: nil, aspect: aspect, at: time)
            }
            return (hands, start.duration(to: clock.now).milliseconds)
        }
        let whole = try await run(nil)
        let asGiven = try await run(
            NormalizedRect(x: crop.minX, y: crop.minY, width: crop.width, height: crop.height)
        )
        // The same region with its vertical origin at the other edge, in case the region counts from the top.
        let flipped = try await run(
            NormalizedRect(x: crop.minX, y: 1 - crop.maxY, width: crop.width, height: crop.height)
        )
        Self.logger.notice("Crop probe: region (\(crop.minX, format: .fixed(precision: 2), privacy: .public),\(crop.minY, format: .fixed(precision: 2), privacy: .public)) \(crop.width, format: .fixed(precision: 2), privacy: .public)x\(crop.height, format: .fixed(precision: 2), privacy: .public) · whole \(describe(whole.hands), privacy: .public) \(whole.milliseconds, format: .fixed(precision: 1), privacy: .public)ms · as-given \(describe(asGiven.hands), privacy: .public) \(asGiven.milliseconds, format: .fixed(precision: 1), privacy: .public)ms · y-flipped \(describe(flipped.hands), privacy: .public) \(flipped.milliseconds, format: .fixed(precision: 1), privacy: .public)ms")
    }

    private func wholeFrame(_ buffer: CVPixelBuffer, aspect: Double, at time: TimeInterval) async throws -> [HandFrame] {
        var request = DetectHumanHandPoseRequest()
        // Two: one operator, two hands. Four cost frame rate for people this app doesn't act on anyway — the
        // operator lock that would need them is v2.
        request.maximumHandCount = 2
        return try await request.perform(on: buffer).map {
            VisionMapping.hand(from: $0, side: nil, aspect: aspect, at: time)
        }
    }

    /// The box every joint of every hand falls inside, in image-normalized coordinates.
    static func box(of hands: [HandFrame]) -> CGRect? {
        let points = hands.flatMap { hand in HandJoint.allCases.compactMap { hand[$0] } }
        guard let first = points.first else { return nil }
        var minimum = first, maximum = first
        for point in points.dropFirst() {
            minimum = Vec2(min(minimum.x, point.x), min(minimum.y, point.y))
            maximum = Vec2(max(maximum.x, point.x), max(maximum.y, point.y))
        }
        return CGRect(
            x: minimum.x, y: minimum.y, width: max(maximum.x - minimum.x, 0), height: max(maximum.y - minimum.y, 0)
        )
    }

    /// A crop around `box`, square in pixels and clamped to the frame. Square because that is the shape the pose
    /// model takes: a tall, narrow region would be squashed into it.
    static func cropRect(around box: CGRect, aspect: Double) -> CGRect {
        // In image heights, so width and height can be compared at all.
        let side = min(max(max(Double(box.height), Double(box.width) * aspect) * cropScale, minCropHeight), 1)
        let width = min(side / aspect, 1)
        let centerX = min(max(Double(box.midX), width / 2), 1 - width / 2)
        let centerY = min(max(Double(box.midY), side / 2), 1 - side / 2)
        return CGRect(x: centerX - width / 2, y: centerY - side / 2, width: width, height: side)
    }
}

private extension Duration {
    var milliseconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) * 1_000 + Double(attoseconds) / 1e15
    }
}
