import CoreImage
import CoreML
import CoreVideo
import Foundation
import GestureCore
import os
import Vision

/// Embeds the largest face in a camera frame with AdaFace IR-18, a few times a second and only while wanted: while
/// the screen is locked, and while the owner enrolls. One frame at a time; frames that arrive while busy are dropped.
final class FaceSource: Sendable {
    struct Output: Sendable {
        let time: TimeInterval
        /// The largest face's embedding; nil when no face with usable landmarks was found.
        let embedding: [Float]?
        /// That face's height as a share of the image height; 0 without one.
        let faceHeight: Double
        let milliseconds: Double
    }

    private struct State: Sendable {
        var wanted = false
        var busy = false
        var lastStart: TimeInterval = -.infinity
        var handler: (@Sendable (Output) -> Void)?
    }

    /// About four checks a second: unlocks within a second, and stays light next to hand tracking.
    private static let interval: TimeInterval = 0.25
    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Face")
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let embedder = OSAllocatedUnfairLock<FaceEmbedder?>(initialState: FaceEmbedder.load())

    /// False when there is no model to run: face unlock and enrollment can't work.
    var isAvailable: Bool { embedder.withLock { $0 != nil } }

    /// Picks up a model that `FaceModelInstaller` put in place while the app was running, so enrollment opens without
    /// a relaunch.
    func reload() {
        let loaded = FaceEmbedder.load()
        embedder.withLock { $0 = loaded }
    }

    var wanted: Bool {
        get { state.withLock { $0.wanted } }
        set { state.withLock { $0.wanted = newValue } }
    }

    func setHandler(_ handler: @escaping @Sendable (Output) -> Void) {
        state.withLock { $0.handler = handler }
    }

    /// Called on the camera queue with every frame; almost all of them return right away.
    func process(_ pixelBuffer: CVPixelBuffer, at time: TimeInterval) {
        guard let embedder = embedder.withLock({ $0 }) else { return }
        let starts = state.withLock {
            guard $0.wanted, !$0.busy, time - $0.lastStart >= Self.interval else { return false }
            $0.busy = true
            $0.lastStart = time
            return true
        }
        guard starts else { return }

        nonisolated(unsafe) let buffer = pixelBuffer
        Task.detached(priority: .utility) {
            let clock = ContinuousClock()
            let start = clock.now
            var embedding: [Float]?
            var faceHeight = 0.0
            do {
                let size = CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
                let faces = try await DetectFaceLandmarksRequest().perform(on: buffer)
                if let face = faces.max(by: { $0.boundingBox.height < $1.boundingBox.height }),
                   let landmarks = face.landmarks,
                   let pupil = landmarks.leftPupil.pointsInImageCoordinates(size, origin: .upperLeft).first,
                   let otherPupil = landmarks.rightPupil.pointsInImageCoordinates(size, origin: .upperLeft).first,
                   let points = FaceAlignment.fivePoints(
                       pupils: (pupil, otherPupil),
                       noseCrest: landmarks.noseCrest.pointsInImageCoordinates(size, origin: .upperLeft),
                       outerLips: landmarks.outerLips.pointsInImageCoordinates(size, origin: .upperLeft)
                   ),
                   FaceAlignment.isPlausible(points, faceWidth: face.boundingBox.width * size.width) {
                    faceHeight = face.boundingBox.height
                    embedding = try embedder.embed(buffer, points: points)
                }
            } catch {
                Self.logger.error("Face check failed: \(String(describing: error), privacy: .public)")
            }
            let output = Output(
                time: time, embedding: embedding, faceHeight: faceHeight,
                milliseconds: Double(start.duration(to: clock.now).components.attoseconds) / 1e15
                    + Double(start.duration(to: clock.now).components.seconds) * 1_000
            )
            let handler = self.state.withLock {
                $0.busy = false
                return $0.handler
            }
            handler?(output)
        }
    }
}

/// Aligns a face and runs the model on it. Used from one detached task at a time (FaceSource's busy flag), and
/// Core ML predictions and Core Image rendering are thread-safe anyway.
private final class FaceEmbedder: @unchecked Sendable {
    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Face")
    private let model: MLModel
    private let context = CIContext(options: [.cacheIntermediates: false])

    private init(model: MLModel) {
        self.model = model
    }

    /// A model installed at runtime wins over one built into the app bundle: the installed one is what the user
    /// just downloaded, and a rebuild is not needed to pick it up.
    static func load() -> FaceEmbedder? {
        let installed = FaceModelInstaller.isInstalled ? FaceModelInstaller.installedURL : nil
        guard let url = installed ?? Bundle.main.url(forResource: FaceModelInstaller.modelName, withExtension: "mlmodelc") else {
            logger.error("No face model installed or in the app bundle: face unlock is off")
            return nil
        }
        do {
            return FaceEmbedder(model: try MLModel(contentsOf: url, configuration: MLModelConfiguration()))
        } catch {
            logger.error("Face model failed to load: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// `points` are the five landmarks in the buffer's pixels, top-left origin.
    func embed(_ buffer: CVPixelBuffer, points: [CGPoint]) throws -> [Float]? {
        guard let alignment = FaceAlignment.similarity(from: points) else { return nil }
        let side = FaceAlignment.size
        // Core Image counts from the bottom: flip into top-left pixels, align, and flip the crop back.
        let fromCoreImage = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(CVPixelBufferGetHeight(buffer)))
        let toCoreImage = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: side)
        let crop = CIImage(cvPixelBuffer: buffer)
            .transformed(by: fromCoreImage.concatenating(alignment).concatenating(toCoreImage))
            .cropped(to: CGRect(x: 0, y: 0, width: side, height: side))
        var aligned: CVPixelBuffer?
        CVPixelBufferCreate(
            nil, Int(side), Int(side), kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &aligned
        )
        guard let aligned else { return nil }
        context.render(crop, to: aligned)
        let input = try MLDictionaryFeatureProvider(dictionary: ["face_image": MLFeatureValue(pixelBuffer: aligned)])
        guard let values = try model.prediction(from: input).featureValue(for: "embedding")?.multiArrayValue else {
            return nil
        }
        return (0..<values.count).map { Float(truncating: values[$0]) }
    }
}
