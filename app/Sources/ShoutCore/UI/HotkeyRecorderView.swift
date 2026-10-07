import AppKit
import Observation
import SwiftUI

/// State for the hotkey recorder control.
///
/// Kept in an @Observable class rather than SwiftUI `@State`: with only the Command Line
/// Tools installed, the macOS 27 SDK's `@State` macro has no compiler plugin.
@MainActor
@Observable
final class HotkeyRecorderModel {
    private(set) var isListening = false
    private(set) var message: String?

    @ObservationIgnored private var monitor: Any?
    @ObservationIgnored private var recorder = HotkeyRecorder()
    @ObservationIgnored private let onListeningChanged: (Bool) -> Void
    @ObservationIgnored private let onRecorded: (Hotkey) -> Void

    init(onListeningChanged: @escaping (Bool) -> Void, onRecorded: @escaping (Hotkey) -> Void) {
        self.onListeningChanged = onListeningChanged
        self.onRecorded = onRecorded
    }

    func toggle() {
        isListening ? stop() : start()
    }

    /// Listens to keys sent to Shout's own (key) Settings window. The global hotkey is
    /// suspended meanwhile so pressing the current hotkey doesn't start a dictation.
    func start() {
        guard !isListening else { return }
        recorder = HotkeyRecorder()
        message = nil
        isListening = true
        onListeningChanged(true)
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .keyUp, .otherMouseDown, .otherMouseUp]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let input = KeyInput(event) else { return event }
            // Local monitors run on the main thread. Returning nil swallows the key so it
            // doesn't beep or type.
            let swallow = MainActor.assumeIsolated { self?.handle(input) ?? false }
            return swallow ? nil : event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard isListening else { return }
        isListening = false
        onListeningChanged(false)
    }

    /// Returns true if the key was consumed by the recorder.
    private func handle(_ input: KeyInput) -> Bool {
        guard isListening else { return false }
        switch recorder.handle(input) {
        case .waiting:
            break
        case let .recorded(hotkey):
            onRecorded(hotkey)
            stop()
        case let .rejected(problem):
            message = problem
        case .cancelled:
            stop()
        }
        return true
    }
}

extension KeyInput {
    /// The same reduction the event tap does, for NSEvents seen by local monitors.
    /// NSEvent's modifierFlags carry the same side-specific bits as CGEventFlags.
    init?(_ event: NSEvent) {
        let flags = UInt64(event.modifierFlags.rawValue)
        switch event.type {
        case .flagsChanged: self = .flagsChanged(keyCode: event.keyCode, flags: flags)
        case .keyDown: self = .keyDown(keyCode: event.keyCode, flags: flags, isRepeat: event.isARepeat)
        case .keyUp: self = .keyUp(keyCode: event.keyCode, flags: flags)
        case .otherMouseDown: self = .mouseDown(button: event.buttonNumber, flags: flags)
        case .otherMouseUp: self = .mouseUp(button: event.buttonNumber, flags: flags)
        default: return nil
        }
    }
}

/// "Click, then press the keys you want" control for the push-to-talk hotkey.
struct HotkeyRecorderView: View {
    @Bindable var settings: AppSettings
    let model: HotkeyRecorderModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(action: model.toggle) {
                    Text(model.isListening ? "Press keys…" : settings.hotkey.displayName)
                        .frame(minWidth: 180)
                        .foregroundStyle(model.isListening ? Color.accentColor : Color.primary)
                }
                .controlSize(.large)
                if model.isListening {
                    Button("Cancel", action: model.stop)
                } else if settings.hotkey != .default {
                    Button("Reset") { settings.hotkey = .default }
                }
            }
            Text(model.message ?? helpText)
                .font(.caption)
                .foregroundStyle(model.message == nil ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear(perform: model.stop)
    }

    private var helpText: String {
        if model.isListening {
            return "Tap a single modifier (e.g. Right ⌥), press a key with modifiers (e.g. ⌃⌥Space), "
                + "or click a side/middle mouse button with the pointer over this window. Esc cancels."
        }
        if settings.hotkey.modifierKey == .function {
            return "Hold to talk. Set System Settings → Keyboard → “Press 🌐 key to” to “Do Nothing”, or macOS will react too."
        }
        return "Hold to talk, release to insert. Press any other key while holding to cancel."
    }
}
