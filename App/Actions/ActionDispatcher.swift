// Media keys use the system-defined event form from the SDK's ev_keymap.h: subtype 8 with the key type and press
// state packed into data1. The paced serial queue follows Pawvis (MIT, © 2026 Alexandria Redmon),
// Sources/Pawvis/Control/MouseController.swift. See THIRD_PARTY_NOTICES.md.

import AppKit
import CoreGraphics
import Foundation
import GestureCore
import QuartzCore

/// Posts the keyboard and media events that gesture actions ask for. Needs the Accessibility permission; without it
/// macOS drops the events silently.
final class ActionDispatcher: @unchecked Sendable {
    private static let minimumGap: TimeInterval = 0.006
    private static let modifierKeyCodes: [Modifier: CGKeyCode] = [
        .command: 0x37, .shift: 0x38, .option: 0x3A, .control: 0x3B,
    ]
    private static let modifierFlags: [Modifier: CGEventFlags] = [
        .command: .maskCommand, .shift: .maskShift, .option: .maskAlternate, .control: .maskControl,
    ]

    private let source = CGEventSource(stateID: .hidSystemState)
    private let queue = DispatchQueue(label: "MotionController.keys", qos: .userInitiated)
    /// Read and written only on `queue`.
    nonisolated(unsafe) private var lastPostTime: TimeInterval = 0

    init() {
        // Otherwise real input is ignored for 0.25 s after every synthetic event.
        source?.localEventsSuppressionInterval = 0
    }

    /// Posts what it can, in order, and returns the actions it has no implementation for.
    func apply(_ actions: [GestureAction]) -> [GestureAction] {
        var unsupported: [GestureAction] = []
        for action in actions {
            switch action {
            case .media(let key): post(key)
            case .keyCombo(let combo): post(combo)
            case .desktop(let direction):
                if !DesktopSwitcher.switchDesktop(direction) {
                    unsupported.append(action)
                }
            }
        }
        return unsupported
    }

    /// NX_KEYTYPE_* values from the SDK's ev_keymap.h.
    private static func keyType(_ key: MediaKey) -> Int {
        switch key {
        case .volumeUp: 0
        case .volumeDown: 1
        case .brightnessUp: 2
        case .brightnessDown: 3
        case .mute: 7
        case .playPause: 16
        case .next: 17
        case .previous: 18
        }
    }

    private func post(_ key: MediaKey) {
        for pressed in [true, false] {
            let state = pressed ? 0x0A : 0x0B
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state) << 8),
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: (Self.keyType(key) << 16) | (state << 8),
                data2: -1
            )?.cgEvent else { continue }
            enqueue(event)
        }
    }

    /// Modifiers go out as real key events, in order. Setting only the flags leaves ⌘Tab's switcher open, waiting
    /// for a Command release that never comes.
    private func post(_ combo: KeyCombo) {
        var flags: CGEventFlags = []
        for modifier in combo.modifiers {
            guard let code = Self.modifierKeyCodes[modifier], let flag = Self.modifierFlags[modifier] else { continue }
            flags.insert(flag)
            enqueue(keyEvent(code, down: true, flags: flags))
        }
        enqueue(keyEvent(CGKeyCode(combo.keyCode), down: true, flags: flags))
        enqueue(keyEvent(CGKeyCode(combo.keyCode), down: false, flags: flags))
        for modifier in combo.modifiers.reversed() {
            guard let code = Self.modifierKeyCodes[modifier], let flag = Self.modifierFlags[modifier] else { continue }
            flags.remove(flag)
            enqueue(keyEvent(code, down: false, flags: flags))
        }
    }

    private func keyEvent(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) -> CGEvent? {
        let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
        event?.flags = flags
        return event
    }

    private func enqueue(_ event: CGEvent?) {
        guard let event else { return }
        nonisolated(unsafe) let posted = event
        queue.async {
            let wait = Self.minimumGap - (CACurrentMediaTime() - self.lastPostTime)
            if wait > 0 {
                usleep(UInt32(wait * 1_000_000))
            }
            posted.post(tap: .cghidEventTap)
            self.lastPostTime = CACurrentMediaTime()
        }
    }
}
