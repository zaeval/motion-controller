// Dock-swipe synthesis. The approach is from Pawvis (MIT, © 2026 Alexandria Redmon),
// Sources/Pawvis/Control/SpaceSwitcher.swift. The field numbers and the event sequence macOS 26 actually accepts —
// three phases, each a Dock-control event followed by a bare companion gesture event, with the direction carried in
// the scroll-gesture flag bits rather than a swipe progress — follow joshuarli/iss (iss.c). A single event with a
// progress value, which is what Pawvis sent, moved nothing here. See THIRD_PARTY_NOTICES.md.

import CoreGraphics
import Foundation
import GestureCore
import os

/// Switches desktops the way a trackpad does, by synthesizing a Dock swipe. Synthetic ⌃←/⌃→ are ignored by macOS —
/// measured again here on 26.5.2, where they left the window server's current desktop untouched — so this is the only
/// way the screen actually moves. Every field is private API: a macOS update can stop it working, which is why the
/// app says so rather than pretending the desktop moved. macOS 27 wants a serialized IOHID payload on top of these
/// fields, which this doesn't build.
enum DesktopSwitcher {
    private static let logger = Logger(subsystem: "com.bori.MotionController", category: "Desktop")
    /// Flip this if a swipe moves the wrong way.
    private static let inverted = false

    /// Undocumented `CGEventField` numbers the window server reads out of a trackpad's Dock swipe.
    private enum Field {
        static let eventType: UInt32 = 55
        static let gestureHIDType: UInt32 = 110
        static let scrollY: UInt32 = 119
        static let swipeMotion: UInt32 = 123
        static let swipeVelocityX: UInt32 = 129
        static let swipeVelocityY: UInt32 = 130
        static let phase: UInt32 = 132
        static let scrollGestureFlagBits: UInt32 = 135
        static let zoomDeltaX: UInt32 = 139
    }

    private static let gestureEvent: Int64 = 29
    private static let dockControlEvent: Int64 = 30
    /// kIOHIDEventTypeDockSwipe.
    private static let dockSwipeGesture: Int64 = 23
    private static let horizontalMotion: Int64 = 1
    /// Began, changed, ended: a swipe that doesn't run through all three moves nothing.
    private static let phases: [Int64] = [1, 2, 4]
    /// Enough to finish the swipe as a flick instead of leaving the desktops half-slid.
    private static let endVelocity = 400.0

    /// Returns false when the events couldn't be built, so the caller can say the feature is unsupported.
    @discardableResult
    static func switchDesktop(_ direction: DesktopDirection) -> Bool {
        // Positive flag bits go to the desktop on the right: with them negative the self test measured 29 → 3, which
        // is one to the left.
        let rightward = (direction == .next) != inverted
        let before = SpaceInfo.currentSpaceID()
        for phase in phases {
            guard let dock = makeDockEvent(phase: phase, rightward: rightward),
                  let companion = CGEvent(source: nil),
                  let eventType = CGEventField(rawValue: Field.eventType)
            else {
                logger.error("Dock-swipe events are unavailable on this macOS")
                return false
            }
            companion.setIntegerValueField(eventType, value: gestureEvent)
            dock.post(tap: .cgSessionEventTap)
            companion.post(tap: .cgSessionEventTap)
        }
        // Whether the desktop actually moved, for the log: a swipe at the end of the row moves nothing, and the
        // window server drops one now and then.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            let after = SpaceInfo.currentSpaceID()
            logger.notice(
                """
                Dock swipe \(direction.rawValue, privacy: .public): space \
                \(before.map(String.init) ?? "unknown", privacy: .public) → \
                \(after.map(String.init) ?? "unknown", privacy: .public)\(before == after ? " (no move)" : "", privacy: .public)
                """
            )
        }
        return true
    }

    /// `open --env MC_DESKTOP_TEST=1 MotionController.app` runs this at launch: it logs which desktop the window
    /// server is on before and after a switch each way, so these private fields can be re-checked after a macOS
    /// update without a gesture and without watching the screen. Launch it through `open`: a binary started directly
    /// has no Accessibility permission and every synthetic event is dropped silently.
    static func runSelfTest() async {
        func space() -> String { SpaceInfo.currentSpaceID().map(String.init) ?? "unknown" }
        logger.notice(
            """
            Self test: desktops \(SpaceInfo.spaceIDs().description, privacy: .public), \
            on \(space(), privacy: .public), accessibility \(AccessibilityPermission.isTrusted, privacy: .public)
            """
        )
        switchDesktop(.next)
        try? await Task.sleep(for: .seconds(2))
        logger.notice("After next: space \(space(), privacy: .public)")
        switchDesktop(.previous)
        try? await Task.sleep(for: .seconds(2))
        logger.notice("After previous: space \(space(), privacy: .public)")
    }

    private static func makeDockEvent(phase: Int64, rightward: Bool) -> CGEvent? {
        guard let event = CGEvent(source: nil),
              let eventType = CGEventField(rawValue: Field.eventType),
              let hidType = CGEventField(rawValue: Field.gestureHIDType),
              let phaseField = CGEventField(rawValue: Field.phase),
              let flagBits = CGEventField(rawValue: Field.scrollGestureFlagBits),
              let motion = CGEventField(rawValue: Field.swipeMotion),
              let scrollY = CGEventField(rawValue: Field.scrollY),
              let zoomDeltaX = CGEventField(rawValue: Field.zoomDeltaX)
        else { return nil }
        event.setIntegerValueField(eventType, value: dockControlEvent)
        event.setIntegerValueField(hidType, value: dockSwipeGesture)
        event.setIntegerValueField(phaseField, value: phase)
        // The direction rides in the sign of the smallest float there is, reinterpreted as the flag bits.
        let nudge = rightward ? Float.leastNonzeroMagnitude : -Float.leastNonzeroMagnitude
        event.setIntegerValueField(flagBits, value: Int64(Int32(bitPattern: nudge.bitPattern)))
        event.setIntegerValueField(motion, value: horizontalMotion)
        event.setDoubleValueField(scrollY, value: 0)
        event.setDoubleValueField(zoomDeltaX, value: Double(Float.leastNonzeroMagnitude))
        guard phase == phases.last,
              let velocityX = CGEventField(rawValue: Field.swipeVelocityX),
              let velocityY = CGEventField(rawValue: Field.swipeVelocityY)
        else { return event }
        event.setDoubleValueField(velocityX, value: (rightward ? 1 : -1) * endVelocity)
        event.setDoubleValueField(velocityY, value: 0)
        return event
    }
}
