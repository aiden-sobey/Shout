import Observation
import ServiceManagement
import SwiftUI

/// Non-persisted state for the Settings window. SwiftUI `@State` isn't usable with only the
/// Command Line Tools (see HotkeyRecorderModel), so view state lives here.
@MainActor
@Observable
final class SettingsModel {
    let hotkeyRecorder: HotkeyRecorderModel
    private(set) var launchAtLogin = SMAppService.mainApp.status == .enabled
    private(set) var launchError: String?

    init(hotkeyRecorder: HotkeyRecorderModel) {
        self.hotkeyRecorder = hotkeyRecorder
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

struct SettingsView: View {
    @Bindable var settings: AppSettings
    let model: SettingsModel
    let microphones: MicrophoneList
    let supervisor: EngineSupervisor
    let downloader: ModelDownloader

    var body: some View {
        TabView {
            GeneralTab(settings: settings, model: model, microphones: microphones)
                .tabItem { Label("General", systemImage: "gearshape") }
            ModelTab(settings: settings, supervisor: supervisor, downloader: downloader)
                .tabItem { Label("Model", systemImage: "waveform") }
            AdvancedTab(settings: settings, supervisor: supervisor)
                .tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
        }
        .padding(20)
        .frame(width: 560, height: 470)
    }
}

private struct GeneralTab: View {
    @Bindable var settings: AppSettings
    let model: SettingsModel
    let microphones: MicrophoneList

    var body: some View {
        Form {
            Section("Push to talk") {
                LabeledContent("Hotkey") {
                    HotkeyRecorderView(settings: settings, model: model.hotkeyRecorder)
                }
                LabeledContent("Microphone") {
                    MicrophonePicker(settings: settings, microphones: microphones)
                }
            }
            Section("Inserting text") {
                Picker("Method", selection: $settings.insertionMethod) {
                    ForEach(InsertionMethod.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if settings.insertionMethod == .paste {
                    Toggle("Restore the clipboard afterwards", isOn: $settings.restoreClipboard)
                    if settings.restoreClipboard {
                        Stepper(value: $settings.restoreDelayMs, in: 100...2000, step: 50) {
                            Text("Restore after \(settings.restoreDelayMs) ms")
                        }
                    }
                }
            }
            Section("Feedback") {
                Toggle("Play sounds", isOn: $settings.playSounds)
                Toggle("Show recording indicator", isOn: $settings.showHUD)
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
                if let launchError = model.launchError {
                    Text(launchError).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelTab: View {
    @Bindable var settings: AppSettings
    let supervisor: EngineSupervisor
    let downloader: ModelDownloader

    private var downloaded: Set<String> { Set(supervisor.status?.downloadedModels ?? []) }
    private var computeTypes: [String] {
        let supported = supervisor.status?.supportedComputeTypes ?? []
        return supported.isEmpty ? [settings.computeType] : supported
    }
    private var sileroMissing: Bool {
        settings.vadMethod == "silero" && supervisor.status?.sileroVadDownloaded == false
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Engine") {
                    Text(supervisor.state.label).foregroundStyle(supervisor.isReady ? Color.secondary : Color.orange)
                }
                Picker("Model", selection: $settings.model) {
                    ForEach(AppSettings.models, id: \.self) { model in
                        Text(modelLabel(model)).tag(model)
                    }
                }
                if !downloaded.contains(settings.model), supervisor.status != nil {
                    downloadRow(settings.model, title: settings.model)
                }
                Picker("Precision", selection: $settings.computeType) {
                    ForEach(computeTypes, id: \.self) { Text(precisionLabel($0)).tag($0) }
                }
                if let error = downloader.lastError {
                    Text(error).font(.caption).foregroundStyle(.orange)
                }
            }
            Section("Tuning") {
                Stepper("CPU threads: \(settings.threads)", value: $settings.threads, in: 1...12)
                Stepper("Beam size: \(settings.beamSize)", value: $settings.beamSize, in: 1...5)
                Picker("Voice detection", selection: $settings.vadMethod) {
                    ForEach(AppSettings.vadMethods, id: \.self) { Text($0).tag($0) }
                }
                if sileroMissing {
                    downloadRow("silero-vad", title: EngineSupervisor.sileroName)
                }
            }
            Section {
                Picker("Spelling", selection: $settings.spelling) {
                    ForEach(Spelling.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Put numbered lists on separate lines", isOn: $settings.formatLists)
            } footer: {
                Text("British rewrites American spellings after transcription. Words like meter, program and license are left alone because their spelling depends on meaning.")
            }
            Section {
                // labelsHidden + a visible border: in a grouped form, a TextField's title
                // otherwise becomes the row label and the empty field looks like plain text.
                TextField("Custom vocabulary", text: $settings.customVocabulary,
                          prompt: Text("e.g. Gridsight, DNSP, WhisperX"), axis: .vertical)
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(2...4)
            } header: {
                Text("Custom vocabulary")
            } footer: {
                Text("Names and jargon, separated by commas.")
            }
        }
        .formStyle(.grouped)
        .task { await supervisor.refreshStatus() }
    }

    private func modelLabel(_ model: String) -> String {
        var label = model
        if let memory = ModelFootprint.memory(model: model, computeType: settings.computeType) {
            label += " · \(memory.label)"
        }
        if supervisor.status != nil, !downloaded.contains(model) {
            label += " · not downloaded"
        }
        return label
    }

    private func precisionLabel(_ computeType: String) -> String {
        guard let memory = ModelFootprint.memory(model: settings.model, computeType: computeType) else {
            return computeType
        }
        return "\(computeType) · \(memory.label)"
    }

    @ViewBuilder
    private func downloadRow(_ name: String, title: String) -> some View {
        HStack {
            if downloader.downloading == name {
                ProgressView().controlSize(.small)
                Text("Downloading \(title)…")
            } else {
                Button("Download \(title)") { download(name) }
                    .disabled(downloader.downloading != nil)
            }
        }
    }

    private func download(_ name: String) {
        guard let directory = settings.engineDirectory else { return }
        Task {
            if await downloader.download(name, engineDirectory: directory) {
                await supervisor.refreshStatus()
                // The supervisor may be sitting in .modelMissing; restarting loads the model.
                if !supervisor.isReady { supervisor.restart() }
            }
        }
    }
}

private struct AdvancedTab: View {
    @Bindable var settings: AppSettings
    let supervisor: EngineSupervisor

    var body: some View {
        Form {
            Section {
                TextField("Engine folder", text: $settings.engineDirectoryOverride, prompt: Text(defaultEnginePath))
                HStack {
                    Button("Restart engine") { supervisor.restart() }
                    Button("Open logs folder") { NSWorkspace.shared.open(Log.directory) }
                }
            } header: {
                Text("Engine")
            } footer: {
                Text("Leave empty to use the folder set when the app was built. Changes apply after restarting the engine.")
            }
            if let status = supervisor.status {
                Section("Versions") {
                    LabeledContent("Engine", value: status.engineVersion)
                    LabeledContent("WhisperX", value: status.whisperxVersion)
                    LabeledContent("Python", value: status.pythonVersion)
                    LabeledContent("Models folder", value: status.modelsDir)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var defaultEnginePath: String {
        Bundle.main.object(forInfoDictionaryKey: "ShoutEngineDirectory") as? String ?? "not set"
    }
}
