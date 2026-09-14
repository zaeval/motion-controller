import Foundation
import Testing
@testable import GestureCore

struct InputLockPolicyTests {
    private static let every: [InputLockPolicy.Event] = [
        .keyDown, .keyUp, .modifiers, .pointerMove, .buttonDown, .buttonUp, .scroll, .other,
    ]
    private let dialog = CGRect(x: 520, y: 300, width: 400, height: 260)

    private func verdict(
        _ event: InputLockPolicy.Event, at location: CGPoint = .zero, asking: Bool, keysReachDialog: Bool = false,
        dialogFrames: [CGRect]? = nil
    ) -> InputLockPolicy.Verdict {
        InputLockPolicy.verdict(
            for: event, at: location, asking: asking, keysReachDialog: keysReachDialog, dialogFrames: dialogFrames ?? [dialog]
        )
    }

    @Test func lockedLetsNothingThroughAndOnlyPressesAskToUnlock() {
        for event in Self.every {
            for location in [CGPoint.zero, CGPoint(x: 700, y: 400)] {
                let result = verdict(event, at: location, asking: false, keysReachDialog: true)
                #expect(!result.passes)
                #expect(result.asksToUnlock == (event == .keyDown || event == .buttonDown))
            }
        }
    }

    @Test func whileAskingKeysGoOnlyWhereTheDialogGetsThem() {
        for event in [InputLockPolicy.Event.keyDown, .keyUp, .modifiers] {
            #expect(verdict(event, asking: true, keysReachDialog: true).passes)
            #expect(!verdict(event, asking: true, keysReachDialog: false).passes)
        }
    }

    @Test func whileAskingThePointerWorksOnlyInsideTheDialog() {
        for event in [InputLockPolicy.Event.pointerMove, .buttonDown, .buttonUp] {
            #expect(verdict(event, at: CGPoint(x: 700, y: 400), asking: true).passes)
            #expect(!verdict(event, at: CGPoint(x: 100, y: 100), asking: true).passes)
        }
    }

    @Test func aDialogThatCantBeFoundStillGetsClicked() {
        #expect(verdict(.buttonDown, at: CGPoint(x: 100, y: 100), asking: true, dialogFrames: []).passes)
        #expect(!verdict(.keyDown, asking: true, dialogFrames: []).passes)
    }

    @Test func scrollingAndGesturesNeverGetThroughAndNothingAsksTwice() {
        for event in Self.every {
            #expect(!verdict(event, at: CGPoint(x: 700, y: 400), asking: true, keysReachDialog: true).asksToUnlock)
        }
        for event in [InputLockPolicy.Event.scroll, .other] {
            #expect(!verdict(event, at: CGPoint(x: 700, y: 400), asking: true, keysReachDialog: true).passes)
        }
    }
}
