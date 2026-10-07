import Carbon.HIToolbox

/// Works out which hotkey the user means while the Settings recorder is listening.
///
/// - Press and release a single modifier with nothing else → that modifier, side-specific.
/// - Press a key while holding modifiers → a combo (bare F-keys are allowed too).
/// - Click a mouse button other than left/right (optionally holding modifiers) → that button.
///   Left and right clicks are ignored so the Cancel button can still be clicked.
/// - Escape with no modifiers → stop recording without changing anything.
public struct HotkeyRecorder: Sendable {
    public enum Outcome: Equatable, Sendable {
        case waiting
        case recorded(Hotkey)
        case rejected(String)
        case cancelled
    }

    /// The modifier that would be recorded if it's released now, if any.
    private var soloModifier: ModifierKey?
    private var sawOtherKey = false

    public init() {}

    public mutating func handle(_ input: KeyInput) -> Outcome {
        switch input {
        case let .flagsChanged(keyCode, flags):
            let heldSideBits = flags & (ModifierKey.allSideMasks | ModifierKey.function.flagMask)
            if let key = ModifierKey(keyCode: keyCode), flags & key.flagMask != 0 {
                // A modifier went down. It can only be a solo hotkey if it's the only one held.
                soloModifier = (heldSideBits == key.flagMask && !sawOtherKey) ? key : nil
                return .waiting
            }
            if heldSideBits == 0 {
                // Everything released.
                defer { soloModifier = nil; sawOtherKey = false }
                if let key = soloModifier {
                    return .recorded(.modifierOnly(key))
                }
            } else {
                // One of several modifiers released: the user meant a combo, not a solo key.
                soloModifier = nil
            }
            return .waiting
        case let .keyDown(keyCode, flags, _):
            sawOtherKey = true
            soloModifier = nil
            let modifiers = HotkeyModifiers(eventFlags: flags)
            if keyCode == UInt16(kVK_Escape) && modifiers.isEmpty {
                return .cancelled
            }
            let hotkey = Hotkey.combo(keyCode: keyCode, modifiers: modifiers)
            if let problem = hotkey.validationError {
                return .rejected(problem)
            }
            return .recorded(hotkey)
        case let .mouseDown(button, flags):
            guard button >= 2 else { return .waiting }
            soloModifier = nil
            let hotkey = Hotkey.mouseButton(button, modifiers: HotkeyModifiers(eventFlags: flags))
            if let problem = hotkey.validationError {
                return .rejected(problem)
            }
            return .recorded(hotkey)
        case .keyUp, .mouseUp:
            return .waiting
        }
    }
}
