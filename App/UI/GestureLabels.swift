import GestureCore

extension StaticPose {
    var displayName: String {
        switch self {
        case .openPalm: "🖐 손바닥"
        case .backOfHand: "🤚 손등"
        case .fist: "✊ 주먹"
        case .pointIndex: "☝️ 검지"
        case .victory: "✌️ 브이"
        case .threeFingers: "🤟 세 손가락"
        case .pinch: "🤏 핀치"
        case .thumbsUp: "👍 엄지척"
        case .pinky: "🤙 새끼손가락"
        }
    }
}

extension InteractionMode {
    var displayName: String {
        switch self {
        case .idle: "IDLE"
        case .normal: "제스처"
        case .pointer: "커서"
        }
    }
}

extension ModeChangeReason {
    /// Why the mode changed, as the log and overlay show it after the mode name.
    var displayName: String {
        switch self {
        case .doubleTap: "톡톡"
        case .fist: "주먹"
        case .idleGesture: "주먹 뒤로"
        case .handLost: "손이 3초 안 보임"
        case .absence: "사람 없음"
        case .menu: "메뉴"
        case .screenLocked: "화면 잠금"
        }
    }
}

extension PointerCalibration.Corner {
    var displayName: String {
        switch self {
        case .topLeft: "왼쪽 위"
        case .topRight: "오른쪽 위"
        case .bottomRight: "오른쪽 아래"
        case .bottomLeft: "왼쪽 아래"
        }
    }
}

extension MediaKey {
    var displayName: String {
        switch self {
        case .playPause: "⏯ 재생/정지"
        case .next: "⏭ 다음 트랙"
        case .previous: "⏮ 이전 트랙"
        case .volumeUp: "🔊 볼륨 +"
        case .volumeDown: "🔉 볼륨 −"
        case .mute: "🔇 음소거"
        case .brightnessUp: "☀️ 밝기 +"
        case .brightnessDown: "🌙 밝기 −"
        }
    }
}

extension GestureAction {
    var displayName: String {
        switch self {
        case .media(let key): key.displayName
        case .keyCombo(let combo): combo == .zoomIn ? "🔍 확대" : combo == .zoomOut ? "🔍 축소" : "⌨️ 단축키"
        case .desktop(let direction): direction == .next ? "🖥 다음 데스크톱" : "🖥 이전 데스크톱"
        }
    }
}

extension PinchAxisControl.Axis {
    var displayName: String { self == .vertical ? "🔊 ↕ 볼륨" : "☀️ ↔ 밝기" }
}

extension ContinuousTarget {
    var displayName: String { self == .volume ? "🔊 볼륨" : "☀️ 밝기" }
}

extension Int {
    /// "+3", "-2", "0".
    var signedText: String { self > 0 ? "+\(self)" : "\(self)" }
}
