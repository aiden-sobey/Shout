import SwiftUI

/// Chooses the microphone to record from. Used in Settings and the setup window.
struct MicrophonePicker: View {
    @Bindable var settings: AppSettings
    let microphones: MicrophoneList

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Picker("Microphone", selection: selection) {
                Text(defaultLabel).tag("")
                ForEach(MicrophoneList.choices(available: microphones.available, saved: settings.microphone), id: \.uid) {
                    Text(label($0)).tag($0.uid)
                }
            }
            .labelsHidden()
            .fixedSize()
            if let saved = settings.microphone, !microphones.isConnected(saved) {
                Text("\(saved.name) isn't connected, so Shout is using the system default until it is.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.trailing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Tagged by UID ("" for the system default), so a renamed device still matches.
    private var selection: Binding<String> {
        Binding(
            get: { settings.microphone?.uid ?? "" },
            set: { uid in
                guard uid != settings.microphone?.uid else { return }
                settings.microphone = microphones.available.first { $0.uid == uid }
            }
        )
    }

    private var defaultLabel: String {
        microphones.defaultName.map { "System default (\($0))" } ?? "System default"
    }

    private func label(_ microphone: Microphone) -> String {
        microphones.isConnected(microphone) ? microphone.name : "\(microphone.name) (not connected)"
    }
}
