import CoreGraphics
import Foundation

/// Carries a face's five landmarks onto the 112×112 template that ArcFace-family recognition models were trained on,
/// so the crop they embed has the eyes, nose and mouth where they expect them.
public enum FaceAlignment {
    /// Side of the aligned crop, in pixels.
    public static let size = 112.0
    /// Eyes, nose tip and mouth corners, left to right in the image, top-left origin.
    public static let template = [
        CGPoint(x: 38.2946, y: 51.6963), CGPoint(x: 73.5318, y: 51.5014), CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655), CGPoint(x: 70.7299, y: 92.2041),
    ]

    /// The five points in template order: whichever eye and mouth corner is further left in the image comes first.
    /// Top-left origin, the same as the template.
    public static func fivePoints(eyes: (CGPoint, CGPoint), nose: CGPoint, mouthCorners: (CGPoint, CGPoint)) -> [CGPoint] {
        let eyes = eyes.0.x <= eyes.1.x ? [eyes.0, eyes.1] : [eyes.1, eyes.0]
        let mouth = mouthCorners.0.x <= mouthCorners.1.x
            ? [mouthCorners.0, mouthCorners.1] : [mouthCorners.1, mouthCorners.0]
        return eyes + [nose] + mouth
    }

    /// The five points from Vision's landmark regions, top-left origin: the pupils, the nose crest's point furthest
    /// from between the eyes (its tip), and the outer-lip points furthest either way along the line through the eyes
    /// (the mouth corners). Measured along the eyes rather than across the image, so a tilted head still works. Nil
    /// when a region is empty or the pupils coincide.
    public static func fivePoints(pupils: (CGPoint, CGPoint), noseCrest: [CGPoint], outerLips: [CGPoint]) -> [CGPoint]? {
        let (first, second) = pupils
        let axis = CGPoint(x: second.x - first.x, y: second.y - first.y)
        let between = CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
        guard axis.x * axis.x + axis.y * axis.y > 1e-9, !noseCrest.isEmpty, outerLips.count >= 2 else { return nil }
        func distance(_ point: CGPoint) -> Double { hypot(point.x - between.x, point.y - between.y) }
        func along(_ point: CGPoint) -> Double { point.x * axis.x + point.y * axis.y }
        guard let tip = noseCrest.max(by: { distance($0) < distance($1) }),
              let leftmost = outerLips.min(by: { along($0) < along($1) }),
              let rightmost = outerLips.max(by: { along($0) < along($1) })
        else { return nil }
        return fivePoints(eyes: pupils, nose: tip, mouthCorners: (leftmost, rightmost))
    }

    /// Whether five template-ordered points look like one face `faceWidth` pixels wide: eyes apart by a sensible share
    /// of it, and the mouth below them by a sensible multiple of that. Landmarks that came back scattered across the
    /// image would otherwise align the whole picture into the crop.
    public static func isPlausible(_ points: [CGPoint], faceWidth: Double) -> Bool {
        guard points.count == 5, faceWidth > 0 else { return false }
        let eyes = hypot(points[1].x - points[0].x, points[1].y - points[0].y)
        let mouthDrop = hypot(
            (points[3].x + points[4].x - points[0].x - points[1].x) / 2,
            (points[3].y + points[4].y - points[0].y - points[1].y) / 2
        )
        return eyes > 0 && (0.2...0.75).contains(eyes / faceWidth) && (0.6...2.0).contains(mouthDrop / eyes)
    }

    /// The least-squares rotation, uniform scale and shift carrying `points` onto `targets` (no mirroring); nil when
    /// the points are all in one place or the counts differ.
    public static func similarity(from points: [CGPoint], to targets: [CGPoint] = template) -> CGAffineTransform? {
        guard points.count == targets.count, points.count >= 2 else { return nil }
        let count = Double(points.count)
        let sourceCenter = CGPoint(x: points.map(\.x).reduce(0, +) / count, y: points.map(\.y).reduce(0, +) / count)
        let targetCenter = CGPoint(x: targets.map(\.x).reduce(0, +) / count, y: targets.map(\.y).reduce(0, +) / count)
        // As complex numbers, the best rotation and scale is Σ conj(p)·q / Σ |p|² over the centered points.
        var real = 0.0
        var imaginary = 0.0
        var spread = 0.0
        for (point, target) in zip(points, targets) {
            let px = point.x - sourceCenter.x, py = point.y - sourceCenter.y
            let qx = target.x - targetCenter.x, qy = target.y - targetCenter.y
            real += px * qx + py * qy
            imaginary += px * qy - py * qx
            spread += px * px + py * py
        }
        guard spread > 1e-9 else { return nil }
        let a = real / spread
        let b = imaginary / spread
        return CGAffineTransform(
            a: a, b: b, c: -b, d: a,
            tx: targetCenter.x - (a * sourceCenter.x - b * sourceCenter.y),
            ty: targetCenter.y - (b * sourceCenter.x + a * sourceCenter.y)
        )
    }
}

/// The owner's enrolled face: the embeddings taken while enrolling, compared against as their normalized mean.
public struct FaceTemplate: Codable, Equatable, Sendable {
    public let embeddings: [[Float]]
    public let mean: [Float]

    /// Nil without embeddings, or with embeddings of different lengths.
    public init?(embeddings: [[Float]]) {
        guard let first = embeddings.first, !first.isEmpty, embeddings.allSatisfy({ $0.count == first.count }) else {
            return nil
        }
        var sum = [Float](repeating: 0, count: first.count)
        for embedding in embeddings {
            let unit = Self.normalized(embedding)
            for index in sum.indices {
                sum[index] += unit[index]
            }
        }
        self.embeddings = embeddings
        mean = Self.normalized(sum)
    }

    /// This template without the embeddings unlike the rest, each compared with the mean of the others: a frame of
    /// someone else, or a bad crop, taken while enrolling.
    public func droppingOutliers(below threshold: Double) -> FaceTemplate {
        guard embeddings.count > 2 else { return self }
        let kept = embeddings.indices.filter { index in
            var others = embeddings
            others.remove(at: index)
            return (FaceTemplate(embeddings: others)?.similarity(to: embeddings[index]) ?? 1) >= threshold
        }.map { embeddings[$0] }
        return FaceTemplate(embeddings: kept) ?? self
    }

    /// Cosine similarity to the owner, -1...1; 0 for an embedding of the wrong length.
    public func similarity(to embedding: [Float]) -> Double {
        Self.cosine(mean, embedding)
    }

    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot = 0.0, normA = 0.0, normB = 0.0
        for index in a.indices {
            dot += Double(a[index]) * Double(b[index])
            normA += Double(a[index]) * Double(a[index])
            normB += Double(b[index]) * Double(b[index])
        }
        guard normA > 0, normB > 0 else { return 0 }
        return dot / (normA.squareRoot() * normB.squareRoot())
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }
}

/// Decides that the owner is in front of the camera from one similarity a checked frame. A single lucky frame isn't
/// enough: several close together have to match, and any face that clearly isn't the owner starts the count over.
public struct FaceVerification: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        /// Cosine similarity to the enrolled face at or above which a frame counts as the owner. Measured 2026-09-14
        /// with AdaFace IR-18: the owner's live frames against their enrollment scored 0.55–0.82; across 51 stock
        /// photos, one person in two different shots scored 0.43–0.82 and two different people at most 0.38.
        public var threshold = 0.45
        /// Matching frames needed, each within `maxGap` of the last.
        public var requiredMatches = 3
        public var maxGap: TimeInterval = 1.0

        public init() {}
    }

    public var settings: Settings
    public private(set) var matches = 0
    private var lastMatch: TimeInterval?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    /// Feeds one checked frame: the largest face's similarity, or nil when no face was found. True once verified.
    public mutating func update(similarity: Double?, at time: TimeInterval) -> Bool {
        if let last = lastMatch, time - last > settings.maxGap {
            matches = 0
            lastMatch = nil
        }
        guard let similarity else { return false }
        guard similarity >= settings.threshold else {
            matches = 0
            lastMatch = nil
            return false
        }
        matches += 1
        lastMatch = time
        return matches >= settings.requiredMatches
    }

    public mutating func reset() {
        matches = 0
        lastMatch = nil
    }
}

/// Collects the owner's face while enrolling: spaced-out samples of a face big enough to embed well, skipping any
/// that don't look like the ones before (someone else leaning in). Once full, any sample unlike the rest is dropped
/// and collecting goes on, so a bad first frame, which nothing before it could catch, doesn't stay in the template.
public struct FaceEnrollment: Sendable {
    public struct Settings: Codable, Equatable, Sendable {
        public var sampleCount = 12
        /// Apart in time, so a turned or tilted head gets in too.
        public var minInterval: TimeInterval = 0.3
        /// Face height as a share of the image height.
        public var minFaceHeight = 0.12
        /// Once a few samples are in, a new one must be at least this similar to them: loose enough for a turned
        /// head, which the owner's own live frames put as low as 0.55.
        public var consistency = 0.45
        /// Once full, a sample less similar than this to the rest is dropped. The first enrollment (2026-09-14) had
        /// eleven frames of the owner within 0.90–0.98 of each other and one bad frame at 0.14.
        public var outlierBelow = 0.6
        public var consistencyAfter = 3

        public init() {}
    }

    public enum Outcome: Equatable, Sendable {
        case added
        case tooSmall
        case tooSoon
        case inconsistent
        case complete
    }

    public var settings: Settings
    public private(set) var embeddings: [[Float]] = []
    private var lastSample: TimeInterval?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public var progress: Double { min(1, Double(embeddings.count) / Double(settings.sampleCount)) }
    public var template: FaceTemplate? {
        embeddings.count >= settings.sampleCount ? FaceTemplate(embeddings: embeddings) : nil
    }

    public mutating func add(_ embedding: [Float], faceHeight: Double, at time: TimeInterval) -> Outcome {
        guard embeddings.count < settings.sampleCount else { return .complete }
        guard faceHeight >= settings.minFaceHeight else { return .tooSmall }
        if let last = lastSample, time - last < settings.minInterval { return .tooSoon }
        if embeddings.count >= settings.consistencyAfter, let sofar = FaceTemplate(embeddings: embeddings),
           sofar.similarity(to: embedding) < settings.consistency {
            return .inconsistent
        }
        embeddings.append(embedding)
        lastSample = time
        if embeddings.count >= settings.sampleCount, let full = FaceTemplate(embeddings: embeddings) {
            embeddings = full.droppingOutliers(below: settings.outlierBelow).embeddings
        }
        return embeddings.count >= settings.sampleCount ? .complete : .added
    }
}
