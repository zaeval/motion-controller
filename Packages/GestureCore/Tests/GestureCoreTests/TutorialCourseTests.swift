import Foundation
import Testing
@testable import GestureCore

struct TutorialCourseTests {
    /// The events that clear every mission, in order.
    private static let playthrough: [TutorialEvent] = [
        .mode(.normal, because: .fist), .playPaused, .zoomed(in: true), .zoomed(in: false), .volumeOrBrightness,
        .mode(.desktop, because: .palmHold), .desktopSwitched, .mode(.pointer, because: .doubleTap),
    ] + Array(repeating: .cursorMoved, count: TutorialCourse.cursorFrames) + [
        .clicked, .rightClicked, .scrolled, .dragged, .mode(.normal, because: .fist),
        .mode(.idle, because: .idleGesture), .faceEnrolled, .cursorCalibrated,
    ]

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
        #expect(course.record(.mode(.normal, because: .fist)) == .enterGestures)
        #expect(course.current == .playPause)
    }

    @Test func zoomNeedsBothWaysAndMovingTheCursorNeedsAMoment() {
        var course = TutorialCourse()
        _ = Self.playthrough.prefix(2).map { course.record($0) }
        #expect(course.current == .zoom)
        #expect(course.record(.zoomed(in: true)) == nil)
        #expect(course.record(.zoomed(in: true)) == nil)
        #expect(course.zoomedIn && !course.zoomedOut)
        #expect(course.record(.zoomed(in: false)) == .zoom)

        _ = course.record(.volumeOrBrightness)
        _ = course.record(.mode(.desktop, because: .palmHold))
        _ = course.record(.desktopSwitched)
        _ = course.record(.mode(.pointer, because: .doubleTap))
        #expect(course.current == .moveCursor)
        let early = (1..<TutorialCourse.cursorFrames).compactMap { _ in course.record(.cursorMoved) }
        #expect(early.isEmpty)
        #expect(course.record(.cursorMoved) == .moveCursor)
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
        // The pump is heard in gesture and desktop mode both, so its mission doesn't demand one.
        #expect(TutorialStep.playPause.requiredMode == nil)
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
