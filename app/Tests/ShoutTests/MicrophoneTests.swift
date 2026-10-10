import Foundation
import Testing
@testable import ShoutCore

@Suite struct MicrophoneSetting {
    let builtIn = Microphone(uid: "BuiltInMicrophoneDevice", name: "MacBook Pro Microphone")
    let usb = Microphone(uid: "AppleUSBAudioEngine:Acme:Desk Mic:1234:1", name: "Desk Mic")

    @MainActor @Test func defaultsToSystemDefaultAndPersists() {
        let defaults = UserDefaults(suiteName: "ShoutTests.\(UUID().uuidString)")!
        let settings = AppSettings(store: defaults)
        #expect(settings.microphone == nil)
        settings.microphone = usb
        #expect(AppSettings(store: defaults).microphone == usb)
        settings.microphone = nil
        #expect(AppSettings(store: defaults).microphone == nil)
    }

    @Test func choicesAreTheConnectedMicrophones() {
        #expect(MicrophoneList.choices(available: [builtIn, usb], saved: nil) == [builtIn, usb])
        #expect(MicrophoneList.choices(available: [builtIn, usb], saved: usb) == [builtIn, usb])
    }

    @Test func anUnpluggedChoiceStaysListed() {
        #expect(MicrophoneList.choices(available: [builtIn], saved: usb) == [builtIn, usb])
    }

    @Test func aRenamedDeviceIsMatchedByUID() {
        let renamed = Microphone(uid: usb.uid, name: "Old name")
        #expect(MicrophoneList.choices(available: [builtIn, usb], saved: renamed) == [builtIn, usb])
    }

    @Test func unknownDeviceIsNotConnected() {
        #expect(AudioDevices.deviceID(forUID: "ShoutTests.no-such-device") == nil)
    }
}
