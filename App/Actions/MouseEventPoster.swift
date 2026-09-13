// Adapted from Pawvis (MIT, © 2026 Alexandria Redmon), Sources/Pawvis/Control/MouseController.swift: the paced
// serial posting queue, skipping a drag immediately followed by its button-up, click states on downs and ups,
// continuous pixel scrolling and the defensive release at launch. See THIRD_PARTY_NOTICES.md.

import CoreGraphics
import Foundation
import GestureCore
import QuartzCore

/// Posts synthetic mouse events for pointer commands on the main display. Needs the Accessibility permission;
/// without it macOS drops the events silently.
///
/// Pacing is load-bearing: Pawvis measured 20% of mouseUps lost when mouse events were posted back to back (none at
/// 4 ms or more), and an app that loses a mouseUp ignores every click after it. Every event goes through one serial
/// queue that keeps at least 6 ms between posts.
final class MouseEventPoster: @unchecked Sendable {
    private static let minimumGap: TimeInterval = 0.006

    /// Screen heights of content scrolled per screen height of hand travel.
    var scrollGain = 2.2

    private let source = CGEventSource(stateID: .hidSystemState)
    private let queue = DispatchQueue(label: "MotionController.mouse", qos: .userInteractive)
    /// Read and written only on `queue`.
    nonisolated(unsafe) private var lastPostTime: TimeInterval = 0

    init() {
        // Otherwise real trackpad and mouse input is ignored for 0.25 s after every synthetic event.
        source?.localEventsSuppressionInterval = 0
    }

    /// Posts commands in order. Call from one thread (the main actor).
    func apply(_ commands: [PointerCommand]) {
        guard !commands.isEmpty else { return }
        let screen = CGDisplayBounds(CGMainDisplayID())
        for (index, command) in commands.enumerated() {
            switch command {
            case .move(let point):
                post(.mouseMoved, at: point, on: screen)
            case .buttonDown(let point, let clickCount):
                post(.leftMouseDown, at: point, on: screen, clickCount: clickCount)
            case .drag(let point):
                // The up carries the final position, and a drag right before it is exactly the tight pair that loses the up.
                if index + 1 < commands.count, case .buttonUp = commands[index + 1] { continue }
                post(.leftMouseDragged, at: point, on: screen)
            case .buttonUp(let point, let clickCount):
                post(.leftMouseUp, at: point, on: screen, clickCount: clickCount)
            case .scroll(let screenHeights):
                postScroll(pixels: screenHeights * screen.height * scrollGain)
            case .rightClick(let point):
                post(.rightMouseDown, at: point, on: screen, clickCount: 1, button: .right)
                post(.rightMouseUp, at: point, on: screen, clickCount: 1, button: .right)
            }
        }
    }

    /// Where the system cursor is now, as a fraction of the main display (clamped), for re-zeroing the hand cursor.
    static func cursorFraction() -> Vec2? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        let screen = CGDisplayBounds(CGMainDisplayID())
        guard screen.width > 0, screen.height > 0 else { return nil }
        return Vec2(
            min(max((location.x - screen.minX) / screen.width, 0), 1),
            min(max((location.y - screen.minY) / screen.height, 0), 1)
        )
    }

    /// Width over height of the main display.
    static var screenAspect: Double {
        let screen = CGDisplayBounds(CGMainDisplayID())
        return screen.height > 0 ? screen.width / screen.height : 1.6
    }

    /// Blocks until every queued event is posted, so a release lands before the process exits or sleeps.
    func flush() {
        queue.sync {}
    }

    /// Clears a left button that a crashed or killed instance may have left down; harmless when nothing is pressed.
    static func postDefensiveRelease() {
        let source = CGEventSource(stateID: .hidSystemState)
        let position = CGEvent(source: nil)?.location ?? .zero
        let event = CGEvent(mouseEventSource: source, mouseType: .leftMouseUp, mouseCursorPosition: position, mouseButton: .left)
        event?.setIntegerValueField(.mouseEventClickState, value: 1)
        event?.post(tap: .cghidEventTap)
    }

    private func post(_ type: CGEventType, at point: Vec2, on screen: CGRect, clickCount: Int = 0, button: CGMouseButton = .left) {
        let location = CGPoint(
            x: min(max(screen.minX + point.x * screen.width, screen.minX), screen.maxX - 1),
            y: min(max(screen.minY + point.y * screen.height, screen.minY), screen.maxY - 1)
        )
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location, mouseButton: button) else { return }
        if [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp].contains(type) {
            // A down or up without a click state is malformed.
            event.setIntegerValueField(.mouseEventClickState, value: Int64(max(clickCount, 1)))
        }
        enqueue(event)
    }

    private func postScroll(pixels: Double) {
        let amount = Int32(pixels.rounded())
        guard amount != 0,
              let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 1, wheel1: amount, wheel2: 0, wheel3: 0)
        else { return }
        // Continuous, like a trackpad, so apps animate it smoothly.
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        enqueue(event)
    }

    private func enqueue(_ event: CGEvent) {
        nonisolated(unsafe) let event = event
        queue.async {
            let wait = Self.minimumGap - (CACurrentMediaTime() - self.lastPostTime)
            if wait > 0 {
                usleep(UInt32(wait * 1_000_000))
            }
            event.post(tap: .cghidEventTap)
            self.lastPostTime = CACurrentMediaTime()
        }
    }
}
