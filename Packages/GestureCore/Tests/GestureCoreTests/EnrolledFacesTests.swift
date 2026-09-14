import Foundation
import Testing
@testable import GestureCore

struct EnrolledFacesTests {
    private func face(_ name: String, _ embedding: [Float]) throws -> EnrolledFace {
        EnrolledFace(name: name, template: try #require(FaceTemplate(embeddings: [embedding])))
    }

    @Test func theClosestEnrolledPersonMatches() throws {
        let people = EnrolledFaces(faces: [try face("나", [1, 0, 0]), try face("동생", [0, 1, 0])])
        let match = try #require(people.bestMatch(for: [0.1, 0.9, 0]))
        #expect(match.face.name == "동생")
        #expect(match.similarity > 0.9)
        #expect(EnrolledFaces().bestMatch(for: [1, 0, 0]) == nil)
    }

    @Test func savingTheSamePersonReplacesThemAndRemovingLeavesTheRest() throws {
        let me = try face("나", [1, 0, 0])
        var people = EnrolledFaces(faces: [me, try face("동생", [0, 1, 0])])
        var updated = me
        updated.template = try #require(FaceTemplate(embeddings: [[0, 0, 1]]))
        people.save(updated)
        #expect(people.faces.count == 2)
        #expect(people.faces.first?.template.mean == [0, 0, 1])
        people.save(try face("친구", [0, 0.5, 0.5]))
        #expect(people.faces.map(\.name) == ["나", "동생", "친구"])
        people.remove(id: me.id)
        #expect(people.faces.map(\.name) == ["동생", "친구"])
    }

    @Test func everyonesTemplateLosesItsOutliers() throws {
        let noisy = try #require(FaceTemplate(embeddings: [[0, 0, 1], [1, 0.1, 0], [1, 0, 0.05], [0.95, 0.05, 0]]))
        let people = EnrolledFaces(faces: [EnrolledFace(name: "나", template: noisy)])
        #expect(people.droppingOutliers(below: 0.6).faces.first?.template.embeddings.count == 3)
    }

    @Test func roundTripsThroughJSON() throws {
        let people = EnrolledFaces(faces: [try face("나", [1, 0, 0])])
        let decoded = try JSONDecoder().decode(EnrolledFaces.self, from: JSONEncoder().encode(people))
        #expect(decoded == people)
    }
}
