import Foundation

/// A media or system key macOS handles itself, showing its own OSD.
public enum MediaKey: String, Codable, Sendable {
    case playPause, next, previous, volumeUp, volumeDown, mute, brightnessUp, brightnessDown
}

public enum Modifier: String, Codable, Sendable {
    case command, shift, option, control
}

/// A key and its modifiers as virtual key codes, so GestureCore stays free of AppKit.
public struct KeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: [Modifier]

    public init(keyCode: UInt16, modifiers: [Modifier] = []) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// Zoom (Accessibility) in and out, with "Use keyboard shortcuts to zoom" on. Synthetic ⌃-scrolls and trackpad
    /// pinches never zoomed anything on macOS 26.5; these shortcuts do.
    public static let zoomIn = KeyCombo(keyCode: 0x18, modifiers: [.option, .command])
    public static let zoomOut = KeyCombo(keyCode: 0x1B, modifiers: [.option, .command])
}

public enum DesktopDirection: String, Codable, Sendable {
    case previous, next
}

/// What a recognized gesture asks the app to do. The app posts the events; GestureCore only decides.
public enum GestureAction: Equatable, Sendable {
    case media(MediaKey)
    case keyCombo(KeyCombo)
    case desktop(DesktopDirection)

    /// One step of a value being dragged: a pinch drag fires dozens, so they belong in a running total rather than
    /// in a log line each.
    public var isContinuousStep: Bool {
        guard case .media(let key) = self else { return false }
        return [.volumeUp, .volumeDown, .brightnessUp, .brightnessDown].contains(key)
    }
}
