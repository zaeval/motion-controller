import Foundation

/// One enrolled person: a name for the menu and the log, and their face.
public struct EnrolledFace: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var template: FaceTemplate
    public var enrolledAt: Date

    public init(id: UUID = UUID(), name: String, template: FaceTemplate, enrolledAt: Date = .now) {
        self.id = id
        self.name = name
        self.template = template
        self.enrolledAt = enrolledAt
    }
}

/// Everyone allowed past the locked screen. The user asked (2026-09-14) for more than one person; any of them
/// unlocks it, and none of them gets photographed.
public struct EnrolledFaces: Codable, Equatable, Sendable {
    public private(set) var faces: [EnrolledFace]

    public init(faces: [EnrolledFace] = []) {
        self.faces = faces
    }

    public var isEmpty: Bool { faces.isEmpty }

    /// The enrolled person this embedding is most like, and how much; nil with nobody enrolled.
    public func bestMatch(for embedding: [Float]) -> (face: EnrolledFace, similarity: Double)? {
        faces.map { ($0, $0.template.similarity(to: embedding)) }.max { $0.1 < $1.1 }
    }

    /// Adds a person, or gives an existing one (same id) their new face and name.
    public mutating func save(_ face: EnrolledFace) {
        if let index = faces.firstIndex(where: { $0.id == face.id }) {
            faces[index] = face
        } else {
            faces.append(face)
        }
    }

    public mutating func remove(id: UUID) {
        faces.removeAll { $0.id == id }
    }

    /// Every template without enrollment frames unlike the rest, as enrolling does now.
    public func droppingOutliers(below threshold: Double) -> EnrolledFaces {
        EnrolledFaces(faces: faces.map { face in
            var cleaned = face
            cleaned.template = face.template.droppingOutliers(below: threshold)
            return cleaned
        })
    }
}
