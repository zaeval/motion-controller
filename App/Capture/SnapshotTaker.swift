import CoreImage
import CoreVideo
import Foundation
import os

/// Turns the next camera frame into a JPEG when asked: the photos of whoever tries to use the Mac while it's locked.
/// Each request carries a tag, handed back with its photo, so a photo that arrives late still lands in the right
/// attempt.
final class SnapshotTaker: Sendable {
    private struct State: Sendable {
        var tags: [Int] = []
        var handler: (@Sendable (Int, Data) -> Void)?
    }

    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Screen")
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let context = CIContext(options: [.cacheIntermediates: false])

    func setHandler(_ handler: @escaping @Sendable (Int, Data) -> Void) {
        state.withLock { $0.handler = handler }
    }

    func request(tag: Int) {
        state.withLock { $0.tags.append(tag) }
    }

    /// Called on the camera queue with every frame; returns right away unless a photo was asked for.
    func process(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        let (tags, handler) = state.withLock { state -> ([Int], (@Sendable (Int, Data) -> Void)?) in
            defer { state.tags = [] }
            return (state.tags, state.handler)
        }
        guard !tags.isEmpty, let handler else { return }
        nonisolated(unsafe) let buffer = pixelBuffer
        let context = context
        Task.detached(priority: .utility) {
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let data = context.jpegRepresentation(of: CIImage(cvPixelBuffer: buffer), colorSpace: colorSpace)
            else {
                Self.logger.error("Photo couldn't be encoded")
                return
            }
            for tag in Set(tags) {
                handler(tag, data)
            }
        }
    }
}
