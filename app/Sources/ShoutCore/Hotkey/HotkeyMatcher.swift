import Carbon.HIToolbox

/// A keyboard or (non-left/right) mouse button event, reduced to what hotkey matching needs.
public enum KeyInput: Equatable, Sendable {
    case flagsChanged(keyCode: UInt16, flags: UInt64)
    case keyDown(keyCode: UInt16, flags: UInt64, isRepeat: Bool)
    case keyUp(keyCode: UInt16, flags: UInt64)
    case mouseDown(button: Int, flags: UInt64)
    case mouseUp(button: Int, flags: UInt64)
}

public enum HotkeyAction: Equatable, Sendable {
    case pressed
    case released
    case cancelled
}

public struct HotkeyDecision: Equatable, Sendable {
    public var action: HotkeyAction?
    /// True when the event should be removed so the focused app never sees it.
    public var swallow: Bool

    public static let passThrough = HotkeyDecision(action: nil, swallow: false)
}

/// Turns raw keyboard events into press / release / cancel for one hotkey.
///
/// Modifier-only hotkeys never swallow events: a modifier on its own types nothing, and
/// hiding modifier changes from apps confuses their modifier state. Combo hotkeys swallow
/// their key's down, repeat and up events so the key doesn't reach the focused app, and
/// mouse-button hotkeys swallow the button's down and up (so "back" doesn't navigate).
///
/// While the hotkey is held, any other key press cancels the recording, because the user
/// is most likely typing a shortcut or special character. Escape cancels and is swallowed.
public struct HotkeyMatcher: Sendable {
    public var hotkey: Hotkey {
        didSet { reset() }
    }
    public private(set) var isHeld = false
    /// Set when the trigger's down event was swallowed, so its up event is swallowed too,
    /// even if the recording was cancelled in between.
    private var swallowRelease = false

    public init(hotkey: Hotkey) {
        self.hotkey = hotkey
    }

    public mutating func reset() {
        isHeld = false
        swallowRelease = false
    }

    public mutating func handle(_ input: KeyInput) -> HotkeyDecision {
        switch hotkey.kind {
        case .modifierOnly: handleModifierOnly(input)
        case .combo: handleCombo(input)
        case .mouseButton: handleMouseButton(input)
        }
    }

    private mutating func handleModifierOnly(_ input: KeyInput) -> HotkeyDecision {
        guard let key = hotkey.modifierKey else { return .passThrough }
        switch input {
        case let .flagsChanged(keyCode, flags) where keyCode == key.keyCode:
            let isDown = flags & key.flagMask != 0
            if isDown && !isHeld {
                // Don't start if another modifier is already held: that's a shortcut.
                let otherModifiers = flags & ModifierKey.allSideMasks & ~key.flagMask
                guard otherModifiers == 0 else { return .passThrough }
                isHeld = true
                return HotkeyDecision(action: .pressed, swallow: false)
            }
            if !isDown && isHeld {
                isHeld = false
                return HotkeyDecision(action: .released, swallow: false)
            }
            return .passThrough
        case let .keyDown(keyCode, _, _) where isHeld:
            return cancel(keyCode: keyCode)
        default:
            return .passThrough
        }
    }

    private mutating func handleCombo(_ input: KeyInput) -> HotkeyDecision {
        switch input {
        case let .keyDown(keyCode, flags, isRepeat) where keyCode == hotkey.keyCode:
            if isHeld || swallowRelease {
                return HotkeyDecision(action: nil, swallow: true)  // auto-repeat
            }
            guard !isRepeat, HotkeyModifiers(eventFlags: flags) == hotkey.modifiers else {
                return .passThrough
            }
            return press()
        case let .keyUp(keyCode, _) where keyCode == hotkey.keyCode && swallowRelease:
            return release()
        case let .keyDown(keyCode, _, _) where isHeld:
            return cancel(keyCode: keyCode)
        default:
            return .passThrough
        }
    }

    private mutating func handleMouseButton(_ input: KeyInput) -> HotkeyDecision {
        guard let button = hotkey.mouseButtonNumber else { return .passThrough }
        switch input {
        case let .mouseDown(number, flags) where number == button:
            if isHeld || swallowRelease {
                return HotkeyDecision(action: nil, swallow: true)
            }
            guard HotkeyModifiers(eventFlags: flags) == hotkey.modifiers else { return .passThrough }
            return press()
        case let .mouseUp(number, _) where number == button && swallowRelease:
            return release()
        case let .keyDown(keyCode, _, _) where isHeld:
            return cancel(keyCode: keyCode)
        default:
            return .passThrough
        }
    }

    // `press` and `release` are for combo and mouse-button hotkeys, which swallow their trigger.

    private mutating func press() -> HotkeyDecision {
        isHeld = true
        swallowRelease = true
        return HotkeyDecision(action: .pressed, swallow: true)
    }

    private mutating func release() -> HotkeyDecision {
        swallowRelease = false
        guard isHeld else { return HotkeyDecision(action: nil, swallow: true) }
        isHeld = false
        return HotkeyDecision(action: .released, swallow: true)
    }

    private mutating func cancel(keyCode: UInt16) -> HotkeyDecision {
        isHeld = false
        return HotkeyDecision(action: .cancelled, swallow: keyCode == UInt16(kVK_Escape))
    }
}
