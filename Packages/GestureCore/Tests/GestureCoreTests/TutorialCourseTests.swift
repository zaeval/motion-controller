import Foundation
import Testing
@testable import GestureCore

struct TutorialCourseTests {
    /// The events that clear every mission, in order — each gesture mission three times over, which is what
    /// clearing one takes.
    private static let playthrough: [TutorialEvent] = thrice([.mode(.normal, because: .fist)])
        + thrice([.playPaused])
        + thrice([.zoomed(in: true), .zoomed(in: false)])
        + thrice([.volumeOrBrightness])
        + thrice([.mode(.desktop, because: .palmHold)])
        + thrice([.desktopSwitched])
        + thrice([.mode(.pointer, because: .doubleTap)])
        + thrice(Array(repeating: .cursorMoved, count: TutorialCourse.cursorFrames))
        + thrice([.clicked]) + thrice([.rightClicked]) + thrice([.scrolled]) + thrice([.dragged])
        + thrice([.mode(.normal, because: .fist)])
        + thrice([.mode(.idle, because: .idleGesture)])
        + [.faceEnrolled, .cursorCalibrated]

    private static func thrice(_ events: [TutorialEvent]) -> [TutorialEvent] {
        events + events + events
    }

    @Test func doingEachFeatureClearsEveryMissionInOrder() {
        var course = TutorialCourse()
        let cleared = Self.playthrough.compactMap { course.record($0) }
        #expect(cleared == TutorialStep.allCases)
        #expect(course.isFinished)
        #expect(TutorialStep.allCases.allSatisfy { course.isCleared($0) })
    }

    @Test func onlyTheCurrentMissionsGestureCounts() {
        var course = TutorialCourse()
        // Out of order, or the right mode for the wrong reason: nothing clears.
        for event: TutorialEvent in [.desktopSwitched, .mode(.normal, because: .menu), .mode(.pointer, because: .doubleTap)] {
            #expect(course.record(event) == nil)
        }
        #expect(course.current == .enterGestures)
        #expect(course.record(.mode(.normal, because: .fist)) == nil)
        #expect(course.record(.mode(.normal, because: .fist)) == nil)
        #expect(course.record(.mode(.normal, because: .fist)) == .enterGestures)
        #expect(course.current == .playPause)
    }

    @Test func zoomNeedsBothWaysAndMovingTheCursorNeedsAMoment() {
        var course = TutorialCourse()
        for _ in 0..<3 { _ = course.record(.mode(.normal, because: .fist)) }
        for _ in 0..<3 { _ = course.record(.playPaused) }
        #expect(course.current == .zoom)
        #expect(course.record(.zoomed(in: true)) == nil)
        #expect(course.record(.zoomed(in: true)) == nil)
        #expect(course.zoomedIn && !course.zoomedOut)
        // Both ways is one go of three, and each go starts over.
        #expect(course.record(.zoomed(in: false)) == nil)
        #expect(!course.zoomedIn && !course.zoomedOut)
        #expect(course.done == 1)
        for _ in 0..<2 {
            _ = course.record(.zoomed(in: true))
            #expect(course.record(.zoomed(in: false)) == (course.done == 2 ? nil : .zoom))
        }
        #expect(course.current == .volumeBrightness)

        for _ in 0..<3 { _ = course.record(.volumeOrBrightness) }
        for _ in 0..<3 { _ = course.record(.mode(.desktop, because: .palmHold)) }
        for _ in 0..<3 { _ = course.record(.desktopSwitched) }
        for _ in 0..<3 { _ = course.record(.mode(.pointer, because: .doubleTap)) }
        #expect(course.current == .moveCursor)
        let early = (1..<TutorialCourse.cursorFrames).compactMap { _ in course.record(.cursorMoved) }
        #expect(early.isEmpty)
        // The frames start over for each of the three goes.
        #expect(course.record(.cursorMoved) == nil)
        #expect(course.cursorFrames == 0)
    }

    /// The two setup missions are a button press, not a gesture: once is enough.
    @Test func eachGestureMissionTakesThreeGoesAndTheSetupOnesOne() {
        #expect(TutorialStep.allCases.filter { $0.repetitions == 1 } == [.enrollFace, .calibrateCursor])
        #expect(TutorialStep.playPause.repetitions == 3)
    }

    @Test func skippingMovesOnWithoutCountingAsCleared() {
        var course = TutorialCourse()
        course.skip()
        #expect(course.current == .playPause)
        #expect(!course.isCleared(.enterGestures))
        for _ in TutorialStep.allCases { course.skip() }
        #expect(course.isFinished)
        course.skip()
        #expect(course.record(.desktopSwitched) == nil)
    }

    @Test func eachMissionSaysWhichModeItNeeds() {
        // Sweeping is only heard in the mode a held palm opens.
        #expect(TutorialStep.switchDesktop.requiredMode == .desktop)
        #expect(TutorialStep.playPause.requiredMode == .normal)
        #expect(TutorialStep.drag.requiredMode == .pointer)
        #expect(TutorialStep.enterCursor.requiredMode == nil)
        #expect(TutorialStep.enterDesktop.requiredMode == nil)
    }

    @Test func theLastTwoMissionsOpenPanelsRatherThanWaitingForAGesture() {
        #expect(TutorialStep.enrollFace.opensPanel)
        #expect(TutorialStep.calibrateCursor.opensPanel)
        #expect(TutorialStep.allCases.suffix(2) == [.enrollFace, .calibrateCursor])
        #expect(!TutorialStep.switchDesktop.opensPanel)
    }
}
