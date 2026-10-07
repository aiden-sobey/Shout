import Carbon.HIToolbox
import CoreGraphics
import Foundation
import Testing
@testable import ShoutCore

// Flag helpers: device-independent bit + side-specific bit, as macOS sends them.
private let rightOptionDown = CGEventFlags.maskAlternate.rawValue | ModifierKey.rightOption.flagMask
private let leftOptionDown = CGEventFlags.maskAlternate.rawValue | ModifierKey.leftOption.flagMask
private let leftCommandDown = CGEventFlags.maskCommand.rawValue | ModifierKey.leftCommand.flagMask
private let controlOption = CGEventFlags.maskControl.rawValue | CGEventFlags.maskAlternate.rawValue
private let space = UInt16(kVK_Space)
private let escape = UInt16(kVK_Escape)
private let keyE = UInt16(kVK_ANSI_E)
private let rightOption = UInt16(kVK_RightOption)

@Suite struct ModifierOnlyMatching {
    var matcher = HotkeyMatcher(hotkey: .modifierOnly(.rightOption))

    @Test mutating func pressAndRelease() {
        #expect(matcher.handle(.flagsChanged(keyCode: rightOption, flags: rightOptionDown))
            == HotkeyDecision(action: .pressed, swallow: false))
        #expect(matcher.isHeld)
        #expect(matcher.handle(.flagsChanged(keyCode: rightOption, flags: 0))
            == HotkeyDecision(action: .released, swallow: false))
        #expect(!matcher.isHeld)
    }

    @Test mutating func leftOptionIsIgnored() {
        let decision = matcher.handle(.flagsChanged(keyCode: UInt16(kVK_Option), flags: leftOptionDown))
        #expect(decision == .passThrough)
        #expect(!matcher.isHeld)
    }

    @Test mutating func doesNotStartWhenAnotherModifierIsHeld() {
        let decision = matcher.handle(.flagsChanged(keyCode: rightOption, flags: rightOptionDown | leftCommandDown))
        #expect(decision == .passThrough)
        #expect(!matcher.isHeld)
    }

    @Test mutating func otherKeyWhileHeldCancelsAndPassesThrough() {
        _ = matcher.handle(.flagsChanged(keyCode: rightOption, flags: rightOptionDown))
        let decision = matcher.handle(.keyDown(keyCode: keyE, flags: rightOptionDown, isRepeat: false))
        #expect(decision == HotkeyDecision(action: .cancelled, swallow: false))
        // Releasing afterwards must not produce a stray release.
        #expect(matcher.handle(.flagsChanged(keyCode: rightOption, flags: 0)) == .passThrough)
    }

    @Test mutating func escapeCancelsAndIsSwallowed() {
        _ = matcher.handle(.flagsChanged(keyCode: rightOption, flags: rightOptionDown))
        let decision = matcher.handle(.keyDown(keyCode: escape, flags: rightOptionDown, isRepeat: false))
        #expect(decision == HotkeyDecision(action: .cancelled, swallow: true))
    }

    @Test mutating func keysWhenNotHeldPassThrough() {
        #expect(matcher.handle(.keyDown(keyCode: keyE, flags: 0, isRepeat: false)) == .passThrough)
        #expect(matcher.handle(.keyDown(keyCode: escape, flags: 0, isRepeat: false)) == .passThrough)
    }

    @Test func functionKey() {
        var fn = HotkeyMatcher(hotkey: .modifierOnly(.function))
        let fnDown = CGEventFlags.maskSecondaryFn.rawValue
        #expect(fn.handle(.flagsChanged(keyCode: UInt16(kVK_Function), flags: fnDown)).action == .pressed)
        #expect(fn.handle(.flagsChanged(keyCode: UInt16(kVK_Function), flags: 0)).action == .released)
    }
}

@Suite struct ComboMatching {
    var matcher = HotkeyMatcher(hotkey: .combo(keyCode: space, modifiers: [.control, .option]))

    @Test mutating func pressRepeatReleaseAreAllSwallowed() {
        #expect(matcher.handle(.keyDown(keyCode: space, flags: controlOption, isRepeat: false))
            == HotkeyDecision(action: .pressed, swallow: true))
        #expect(matcher.handle(.keyDown(keyCode: space, flags: controlOption, isRepeat: true))
            == HotkeyDecision(action: nil, swallow: true))
        #expect(matcher.handle(.keyUp(keyCode: space, flags: controlOption))
            == HotkeyDecision(action: .released, swallow: true))
        // Plain Space afterwards is untouched.
        #expect(matcher.handle(.keyDown(keyCode: space, flags: 0, isRepeat: false)) == .passThrough)
        #expect(matcher.handle(.keyUp(keyCode: space, flags: 0)) == .passThrough)
    }

    @Test mutating func wrongModifiersPassThrough() {
        let shiftOnly = CGEventFlags.maskShift.rawValue
        #expect(matcher.handle(.keyDown(keyCode: space, flags: shiftOnly, isRepeat: false)) == .passThrough)
        let extra = controlOption | CGEventFlags.maskCommand.rawValue
        #expect(matcher.handle(.keyDown(keyCode: space, flags: extra, isRepeat: false)) == .passThrough)
    }

    @Test mutating func fnAndCapsLockDoNotBreakMatching() {
        let noisy = controlOption | CGEventFlags.maskSecondaryFn.rawValue | CGEventFlags.maskAlphaShift.rawValue
        #expect(matcher.handle(.keyDown(keyCode: space, flags: noisy, isRepeat: false)).action == .pressed)
    }

    @Test mutating func releasingModifiersFirstStillReleasesOnKeyUp() {
        _ = matcher.handle(.keyDown(keyCode: space, flags: controlOption, isRepeat: false))
        #expect(matcher.handle(.flagsChanged(keyCode: UInt16(kVK_Control), flags: 0)) == .passThrough)
        #expect(matcher.handle(.keyUp(keyCode: space, flags: 0)).action == .released)
    }

    @Test mutating func otherKeyCancelsThenKeyUpIsStillSwallowed() {
        _ = matcher.handle(.keyDown(keyCode: space, flags: controlOption, isRepeat: false))
        #expect(matcher.handle(.keyDown(keyCode: keyE, flags: controlOption, isRepeat: false))
            == HotkeyDecision(action: .cancelled, swallow: false))
        #expect(matcher.handle(.keyDown(keyCode: space, flags: controlOption, isRepeat: true))
            == HotkeyDecision(action: nil, swallow: true))
        #expect(matcher.handle(.keyUp(keyCode: space, flags: controlOption))
            == HotkeyDecision(action: nil, swallow: true))
    }

    @Test func bareFunctionKey() {
        var f13 = HotkeyMatcher(hotkey: .combo(keyCode: UInt16(kVK_F13), modifiers: []))
        let fnFlag = CGEventFlags.maskSecondaryFn.rawValue
        #expect(f13.handle(.keyDown(keyCode: UInt16(kVK_F13), flags: fnFlag, isRepeat: false)).action == .pressed)
        #expect(f13.handle(.keyUp(keyCode: UInt16(kVK_F13), flags: fnFlag)).action == .released)
    }

    @Test mutating func changingHotkeyResetsState() {
        _ = matcher.handle(.keyDown(keyCode: space, flags: controlOption, isRepeat: false))
        matcher.hotkey = .modifierOnly(.rightOption)
        #expect(!matcher.isHeld)
    }
}

@Suite struct Recording {
    @Test func tappingASingleModifierRecordsItWithItsSide() {
        var recorder = HotkeyRecorder()
        #expect(recorder.handle(.flagsChanged(keyCode: rightOption, flags: rightOptionDown)) == .waiting)
        #expect(recorder.handle(.flagsChanged(keyCode: rightOption, flags: 0)) == .recorded(.modifierOnly(.rightOption)))
    }

    @Test func modifiersPlusKeyRecordsACombo() {
        var recorder = HotkeyRecorder()
        _ = recorder.handle(.flagsChanged(keyCode: UInt16(kVK_Control), flags: CGEventFlags.maskControl.rawValue | 0x1))
        _ = recorder.handle(.flagsChanged(keyCode: UInt16(kVK_Option), flags: controlOption | 0x1 | 0x20))
        let outcome = recorder.handle(.keyDown(keyCode: space, flags: controlOption | 0x1 | 0x20, isRepeat: false))
        #expect(outcome == .recorded(.combo(keyCode: space, modifiers: [.control, .option])))
    }

    @Test func twoModifiersReleasedWithoutAKeyRecordNothing() {
        var recorder = HotkeyRecorder()
        _ = recorder.handle(.flagsChanged(keyCode: rightOption, flags: rightOptionDown))
        _ = recorder.handle(.flagsChanged(keyCode: UInt16(kVK_Command), flags: rightOptionDown | leftCommandDown))
        #expect(recorder.handle(.flagsChanged(keyCode: UInt16(kVK_Command), flags: rightOptionDown)) == .waiting)
        #expect(recorder.handle(.flagsChanged(keyCode: rightOption, flags: 0)) == .waiting)
    }

    @Test func bareLetterIsRejected() {
        var recorder = HotkeyRecorder()
        guard case .rejected = recorder.handle(.keyDown(keyCode: keyE, flags: 0, isRepeat: false)) else {
            Issue.record("expected rejection")
            return
        }
    }

    @Test func bareFunctionKeyIsAccepted() {
        var recorder = HotkeyRecorder()
        let outcome = recorder.handle(.keyDown(keyCode: UInt16(kVK_F13), flags: CGEventFlags.maskSecondaryFn.rawValue, isRepeat: false))
        #expect(outcome == .recorded(.combo(keyCode: UInt16(kVK_F13), modifiers: [])))
    }

    @Test func escapeCancels() {
        var recorder = HotkeyRecorder()
        #expect(recorder.handle(.keyDown(keyCode: escape, flags: 0, isRepeat: false)) == .cancelled)
    }
}

@Suite struct HotkeyModel {
    @Test func displayNames() {
        #expect(Hotkey.default.displayName == "Right ⌥ Option")
        #expect(Hotkey.combo(keyCode: space, modifiers: [.command, .control, .option]).displayName == "⌃⌥⌘Space")
        #expect(Hotkey.combo(keyCode: UInt16(kVK_F13), modifiers: []).displayName == "F13")
    }

    @Test func codableRoundTrip() throws {
        for hotkey in [Hotkey.default, .modifierOnly(.function), .combo(keyCode: space, modifiers: [.shift, .command])] {
            let data = try JSONEncoder().encode(hotkey)
            #expect(try JSONDecoder().decode(Hotkey.self, from: data) == hotkey)
        }
    }

    @Test func validation() {
        #expect(Hotkey.default.validationError == nil)
        #expect(Hotkey.combo(keyCode: escape, modifiers: [.control]).validationError != nil)
        #expect(Hotkey.combo(keyCode: keyE, modifiers: []).validationError != nil)
        #expect(Hotkey.combo(keyCode: keyE, modifiers: [.control]).validationError == nil)
    }

    @MainActor @Test func settingsPersistHotkey() {
        let defaults = UserDefaults(suiteName: "ShoutTests.\(UUID().uuidString)")!
        let settings = AppSettings(store: defaults)
        #expect(settings.hotkey == .default)
        settings.hotkey = .combo(keyCode: space, modifiers: [.control, .option])
        #expect(AppSettings(store: defaults).hotkey == .combo(keyCode: space, modifiers: [.control, .option]))
    }
}

@Suite struct MouseButtonMatching {
    var matcher = HotkeyMatcher(hotkey: .mouseButton(3))

    @Test mutating func pressAndReleaseAreSwallowed() {
        #expect(matcher.handle(.mouseDown(button: 3, flags: 0)) == HotkeyDecision(action: .pressed, swallow: true))
        #expect(matcher.isHeld)
        #expect(matcher.handle(.mouseUp(button: 3, flags: 0)) == HotkeyDecision(action: .released, swallow: true))
        #expect(!matcher.isHeld)
    }

    @Test mutating func otherButtonsPassThrough() {
        #expect(matcher.handle(.mouseDown(button: 4, flags: 0)) == .passThrough)
        #expect(matcher.handle(.mouseUp(button: 4, flags: 0)) == .passThrough)
        #expect(matcher.handle(.mouseDown(button: 2, flags: 0)) == .passThrough)
    }

    @Test mutating func keyPressWhileHeldCancelsButButtonUpIsStillSwallowed() {
        _ = matcher.handle(.mouseDown(button: 3, flags: 0))
        #expect(matcher.handle(.keyDown(keyCode: keyE, flags: 0, isRepeat: false))
            == HotkeyDecision(action: .cancelled, swallow: false))
        // The browser must not see a lone "back" button-up.
        #expect(matcher.handle(.mouseUp(button: 3, flags: 0)) == HotkeyDecision(action: nil, swallow: true))
    }

    @Test mutating func escapeCancelsAndIsSwallowed() {
        _ = matcher.handle(.mouseDown(button: 3, flags: 0))
        #expect(matcher.handle(.keyDown(keyCode: escape, flags: 0, isRepeat: false))
            == HotkeyDecision(action: .cancelled, swallow: true))
    }

    @Test func modifiersMustMatch() {
        var withOption = HotkeyMatcher(hotkey: .mouseButton(2, modifiers: [.option]))
        #expect(withOption.handle(.mouseDown(button: 2, flags: 0)) == .passThrough)
        #expect(withOption.handle(.mouseDown(button: 2, flags: CGEventFlags.maskAlternate.rawValue)).action == .pressed)
    }

    @Test func keyboardHotkeysIgnoreMouseButtons() {
        var keyboard = HotkeyMatcher(hotkey: .default)
        #expect(keyboard.handle(.mouseDown(button: 3, flags: 0)) == .passThrough)
        var combo = HotkeyMatcher(hotkey: .combo(keyCode: space, modifiers: [.control]))
        #expect(combo.handle(.mouseDown(button: 3, flags: 0)) == .passThrough)
    }
}

@Suite struct MouseButtonRecording {
    @Test func sideButtonIsRecorded() {
        var recorder = HotkeyRecorder()
        #expect(recorder.handle(.mouseDown(button: 3, flags: 0)) == .recorded(.mouseButton(3)))
    }

    @Test func modifiersAreKept() {
        var recorder = HotkeyRecorder()
        let flags = CGEventFlags.maskControl.rawValue | 0x1
        #expect(recorder.handle(.mouseDown(button: 4, flags: flags)) == .recorded(.mouseButton(4, modifiers: [.control])))
    }

    @Test func leftAndRightClicksAreIgnored() {
        var recorder = HotkeyRecorder()
        #expect(recorder.handle(.mouseDown(button: 0, flags: 0)) == .waiting)
        #expect(recorder.handle(.mouseDown(button: 1, flags: 0)) == .waiting)
    }

    @Test func namesAndValidation() {
        #expect(Hotkey.mouseButton(2).displayName == "Middle Click")
        #expect(Hotkey.mouseButton(3).displayName == "Mouse Button 4 (Back)")
        #expect(Hotkey.mouseButton(4, modifiers: [.option]).displayName == "⌥Mouse Button 5 (Forward)")
        #expect(Hotkey.mouseButton(7).displayName == "Mouse Button 8")
        #expect(Hotkey.mouseButton(1).validationError != nil)
        #expect(Hotkey.mouseButton(3).validationError == nil)
    }

    @Test func codableRoundTrip() throws {
        let hotkey = Hotkey.mouseButton(3, modifiers: [.shift])
        #expect(try JSONDecoder().decode(Hotkey.self, from: JSONEncoder().encode(hotkey)) == hotkey)
    }
}

@Suite struct SpellingSetting {
    @MainActor @Test func defaultsToBritishAndIsSentToTheEngine() {
        let defaults = UserDefaults(suiteName: "ShoutTests.\(UUID().uuidString)")!
        let settings = AppSettings(store: defaults)
        #expect(settings.spelling == .british)
        #expect(settings.transcribeOptions.spelling == "en-GB")
        settings.spelling = .american
        #expect(AppSettings(store: defaults).transcribeOptions.spelling == "en-US")
    }
}

@Suite struct ListFormattingSetting {
    @MainActor @Test func defaultsOnAndIsSentToTheEngine() throws {
        let defaults = UserDefaults(suiteName: "ShoutTests.\(UUID().uuidString)")!
        let settings = AppSettings(store: defaults)
        #expect(settings.formatLists)
        let data = try EngineCoding.encoder.encode(settings.transcribeOptions)
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #expect(object["format_lists"] as? Bool == true)
        settings.formatLists = false
        #expect(AppSettings(store: defaults).transcribeOptions.formatLists == false)
    }
}
