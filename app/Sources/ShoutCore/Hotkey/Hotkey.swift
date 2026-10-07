import Carbon.HIToolbox
import CoreGraphics

/// The push-to-talk trigger: a single modifier key held on its own (e.g. Right Option),
/// a key plus modifiers (e.g. ⌃⌥Space, or a bare F13), or a mouse button other than
/// left/right (e.g. the side "back" button), optionally with modifiers.
public struct Hotkey: Codable, Equatable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case modifierOnly
        case combo
        case mouseButton
    }

    public var kind: Kind
    /// The virtual key code for keyboard hotkeys. For `.mouseButton` it holds the button
    /// number instead (2 = middle, 3 = back, 4 = forward, …); see `mouseButtonNumber`.
    public var keyCode: UInt16
    /// Required modifiers for `.combo` and `.mouseButton`. Side-agnostic. Always empty
    /// for `.modifierOnly`.
    public var modifiers: HotkeyModifiers

    public init(kind: Kind, keyCode: UInt16, modifiers: HotkeyModifiers = []) {
        self.kind = kind
        self.keyCode = keyCode
        self.modifiers = kind == .modifierOnly ? [] : modifiers
    }

    public static func modifierOnly(_ key: ModifierKey) -> Hotkey {
        Hotkey(kind: .modifierOnly, keyCode: key.keyCode)
    }

    public static func combo(keyCode: UInt16, modifiers: HotkeyModifiers) -> Hotkey {
        Hotkey(kind: .combo, keyCode: keyCode, modifiers: modifiers)
    }

    public static func mouseButton(_ number: Int, modifiers: HotkeyModifiers = []) -> Hotkey {
        Hotkey(kind: .mouseButton, keyCode: UInt16(clamping: number), modifiers: modifiers)
    }

    public static let `default` = Hotkey.modifierOnly(.rightOption)

    public var modifierKey: ModifierKey? {
        kind == .modifierOnly ? ModifierKey(keyCode: keyCode) : nil
    }

    public var mouseButtonNumber: Int? {
        kind == .mouseButton ? Int(keyCode) : nil
    }

    public var displayName: String {
        switch kind {
        case .modifierOnly:
            return modifierKey?.displayName ?? "Key \(keyCode)"
        case .combo:
            return modifiers.symbols + KeyNames.name(for: keyCode)
        case .mouseButton:
            return modifiers.symbols + KeyNames.mouseButtonName(Int(keyCode))
        }
    }

    /// Why this hotkey can't be used, or nil if it's fine.
    public var validationError: String? {
        switch kind {
        case .modifierOnly:
            return modifierKey == nil ? "That key can't be used on its own." : nil
        case .combo:
            if ModifierKey(keyCode: keyCode) != nil {
                return "Pick a modifier on its own, or a key plus modifiers."
            }
            if keyCode == UInt16(kVK_Escape) {
                return "Escape is reserved for cancelling a recording."
            }
            if modifiers.isEmpty && !KeyNames.isFunctionKey(keyCode) {
                return "Add a modifier (⌘ ⌥ ⌃ ⇧). Only F1–F20 work without one."
            }
            return nil
        case .mouseButton:
            return keyCode < 2 ? "Left and right click can't be used. Try a side or middle button." : nil
        }
    }
}

/// Side-agnostic modifiers for combo hotkeys, stored as CGEventFlags bits.
public struct HotkeyModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let control = HotkeyModifiers(rawValue: CGEventFlags.maskControl.rawValue)
    public static let option = HotkeyModifiers(rawValue: CGEventFlags.maskAlternate.rawValue)
    public static let shift = HotkeyModifiers(rawValue: CGEventFlags.maskShift.rawValue)
    public static let command = HotkeyModifiers(rawValue: CGEventFlags.maskCommand.rawValue)

    static let all: HotkeyModifiers = [.control, .option, .shift, .command]

    /// The modifiers present in a raw event flags value. Fn and Caps Lock are ignored:
    /// macOS sets Fn on arrow and function keys by itself.
    public init(eventFlags: UInt64) {
        self.init(rawValue: eventFlags & HotkeyModifiers.all.rawValue)
    }

    /// In the order macOS menus show them.
    public var symbols: String {
        var result = ""
        if contains(.control) { result += "⌃" }
        if contains(.option) { result += "⌥" }
        if contains(.shift) { result += "⇧" }
        if contains(.command) { result += "⌘" }
        return result
    }
}

/// A modifier key that can be the hotkey on its own. Sides are told apart with the
/// device-dependent bits in the low word of the event flags (NX_DEVICE*KEYMASK).
public enum ModifierKey: CaseIterable, Sendable {
    case rightOption, leftOption
    case rightCommand, leftCommand
    case rightControl, leftControl
    case rightShift, leftShift
    case function

    public init?(keyCode: UInt16) {
        guard let match = ModifierKey.allCases.first(where: { $0.keyCode == keyCode }) else { return nil }
        self = match
    }

    public var keyCode: UInt16 {
        switch self {
        case .rightOption: UInt16(kVK_RightOption)
        case .leftOption: UInt16(kVK_Option)
        case .rightCommand: UInt16(kVK_RightCommand)
        case .leftCommand: UInt16(kVK_Command)
        case .rightControl: UInt16(kVK_RightControl)
        case .leftControl: UInt16(kVK_Control)
        case .rightShift: UInt16(kVK_RightShift)
        case .leftShift: UInt16(kVK_Shift)
        case .function: UInt16(kVK_Function)
        }
    }

    /// The flag bit that is set while this exact key is down.
    public var flagMask: UInt64 {
        switch self {
        case .leftControl: 0x0000_0001
        case .leftShift: 0x0000_0002
        case .rightShift: 0x0000_0004
        case .leftCommand: 0x0000_0008
        case .rightCommand: 0x0000_0010
        case .leftOption: 0x0000_0020
        case .rightOption: 0x0000_0040
        case .rightControl: 0x0000_2000
        case .function: CGEventFlags.maskSecondaryFn.rawValue
        }
    }

    /// Bits for every side-specific modifier except Fn.
    static let allSideMasks: UInt64 = ModifierKey.allCases
        .filter { $0 != .function }
        .reduce(0) { $0 | $1.flagMask }

    public var displayName: String {
        switch self {
        case .rightOption: "Right ⌥ Option"
        case .leftOption: "Left ⌥ Option"
        case .rightCommand: "Right ⌘ Command"
        case .leftCommand: "Left ⌘ Command"
        case .rightControl: "Right ⌃ Control"
        case .leftControl: "Left ⌃ Control"
        case .rightShift: "Right ⇧ Shift"
        case .leftShift: "Left ⇧ Shift"
        case .function: "fn / 🌐"
        }
    }
}

enum KeyNames {
    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        functionKeys[Int(keyCode)] != nil
    }

    /// Button numbers as macOS reports them: 0 left, 1 right, 2 middle, 3 back, 4 forward.
    static func mouseButtonName(_ number: Int) -> String {
        switch number {
        case 2: "Middle Click"
        case 3: "Mouse Button 4 (Back)"
        case 4: "Mouse Button 5 (Forward)"
        default: "Mouse Button \(number + 1)"
        }
    }

    static func name(for keyCode: UInt16) -> String {
        let code = Int(keyCode)
        return functionKeys[code] ?? specialKeys[code] ?? ansiKeys[code] ?? "Key \(keyCode)"
    }

    private static let functionKeys: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
        kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    private static let specialKeys: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
        kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ANSI_KeypadEnter: "⌤",
    ]

    // US ANSI layout. Good enough for showing a shortcut back to the user.
    private static let ansiKeys: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E",
        kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J",
        kVK_ANSI_K: "K", kVK_ANSI_L: "L", kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O",
        kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
        kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X", kVK_ANSI_Y: "Y",
        kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_LeftBracket: "[",
        kVK_ANSI_RightBracket: "]", kVK_ANSI_Backslash: "\\", kVK_ANSI_Semicolon: ";",
        kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".", kVK_ANSI_Slash: "/",
        kVK_ANSI_Grave: "`",
    ]
}
