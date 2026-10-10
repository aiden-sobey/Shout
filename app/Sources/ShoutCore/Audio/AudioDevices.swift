import CoreAudio
import Foundation
import Observation

/// A microphone as saved in settings. Core Audio's numeric device IDs change when a device
/// is reconnected or the Mac restarts; the UID doesn't. The name is kept so the setting can
/// still be shown while the device is unplugged.
public struct Microphone: Codable, Hashable, Sendable {
    public var uid: String
    public var name: String

    public init(uid: String, name: String) {
        self.uid = uid
        self.name = name
    }
}

/// Reads input devices from Core Audio. Listing them needs no permission.
public enum AudioDevices {
    private static let system = AudioObjectID(kAudioObjectSystemObject)

    /// Every connected device that can record, sorted by name.
    public static func inputs() -> [Microphone] {
        deviceIDs()
            .filter { hasInput($0) && !isHidden($0) }
            .compactMap { id in
                guard let uid = string(id, kAudioDevicePropertyDeviceUID),
                      let name = string(id, kAudioObjectPropertyName) else { return nil }
                return Microphone(uid: uid, name: name)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The input chosen in System Settings → Sound.
    public static func defaultInputName() -> String? {
        var address = address(kAudioHardwarePropertyDefaultInputDevice)
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return string(id, kAudioObjectPropertyName)
    }

    /// The current device ID for a saved microphone, or nil if it isn't connected.
    public static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid && hasInput($0) }
    }

    /// Calls `onChange` on the main queue when a device is connected or removed, or the
    /// default input changes. The listeners stay for the life of the process.
    static func observeChanges(_ onChange: @escaping @Sendable () -> Void) {
        for selector in [kAudioHardwarePropertyDevices, kAudioHardwarePropertyDefaultInputDevice] {
            var address = address(selector)
            AudioObjectAddPropertyListenerBlock(system, &address, .main) { _, _ in onChange() }
        }
    }

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr && size > 0
    }

    /// Hidden devices include the private aggregates other apps create behind the scenes.
    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var address = address(kAudioDevicePropertyIsHidden)
        var hidden: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &hidden) == noErr && hidden != 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
}

/// The connected microphones, kept current as devices come and go, for the pickers.
@MainActor
@Observable
public final class MicrophoneList {
    public private(set) var available: [Microphone] = []
    public private(set) var defaultName: String?

    public init() {
        refresh()
        AudioDevices.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    public func refresh() {
        available = AudioDevices.inputs()
        defaultName = AudioDevices.defaultInputName()
    }

    public func isConnected(_ microphone: Microphone) -> Bool {
        available.contains { $0.uid == microphone.uid }
    }

    /// The picker's choices: what's connected, plus the saved microphone if it's unplugged,
    /// so the setting is still visible (and kept) until it comes back.
    public nonisolated static func choices(available: [Microphone], saved: Microphone?) -> [Microphone] {
        guard let saved, !available.contains(where: { $0.uid == saved.uid }) else { return available }
        return available + [saved]
    }
}
