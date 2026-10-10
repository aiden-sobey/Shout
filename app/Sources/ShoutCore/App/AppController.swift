import AppKit
import SwiftUI

/// Builds every part of the app and wires them together.
@MainActor
public final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let settings = AppSettings()
    private let permissions = Permissions()
    private let microphones = MicrophoneList()
    private let downloader = ModelDownloader()
    private let recorder = AudioRecorder()
    private let hud = RecordingHUD()
    private let sounds = Sounds()
    private var supervisor: EngineSupervisor!
    private var controller: DictationController!
    private var monitor: HotkeyMonitor!
    private var menuBar: MenuBarController!

    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var permissionTimer: Timer?
    private var hotkeyTapFailed = false
    private var configTask: Task<Void, Never>?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        supervisor = EngineSupervisor(config: settings.modelConfig, engineDirectory: settings.engineDirectory)
        controller = DictationController(
            recorder: recorder,
            engine: LiveTranscriber(supervisor: supervisor, settings: settings),
            inserter: LiveInserter(inserter: TextInserter(), settings: settings),
            system: LiveSystemContext()
        )
        controller.onCue = { [weak self] cue in
            guard let self, settings.playSounds else { return }
            sounds.play(cue)
        }
        monitor = HotkeyMonitor(hotkey: settings.hotkey) { [weak self] action in
            MainActor.assumeIsolated { self?.controller.handle(action) }
        }
        let hudModel = hud.model
        recorder.onLevel = { level in
            DispatchQueue.main.async { MainActor.assumeIsolated { hudModel.level = level } }
        }
        recorder.onInterrupted = { [weak self] in
            MainActor.assumeIsolated { self?.controller.recordingInterrupted() }
        }

        menuBar = MenuBarController(
            controller: controller,
            supervisor: supervisor,
            permissions: permissions,
            settings: settings,
            hotkeyTapRunning: { [weak self] in self?.monitor.isRunning ?? false },
            actions: .init(
                pasteLast: { [weak self] in
                    // Give the menu a moment to close so the target app has focus again.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        await self?.controller.pasteLastTranscript()
                    }
                },
                copyTranscript: { record in
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(record.text, forType: .string)
                },
                openSettings: { [weak self] in self?.showSettings() },
                openPermissions: { [weak self] in self?.showOnboarding() },
                quit: { NSApp.terminate(nil) }
            )
        )

        observeSettings()
        observeDictation()
        supervisor.start()

        permissions.refresh()
        Log.app.info("Launch: microphone \(String(describing: self.permissions.microphone), privacy: .public), accessibility \(self.permissions.accessibility, privacy: .public)")
        if permissions.allGranted && startHotkey() {
            Log.app.info("Ready; hotkey \(self.settings.hotkey.displayName)")
        } else {
            showOnboarding()
        }
    }

    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        monitor?.stop()
        guard let supervisor else { return .terminateNow }
        Task {
            await supervisor.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    // MARK: - Wiring

    private func observeSettings() {
        observeChanges { [weak self] in
            guard let self else { return }
            monitor.update(hotkey: settings.hotkey)
        }
        observeChanges { [weak self] in
            guard let self else { return }
            recorder.inputDeviceUID = settings.microphone?.uid
        }
        var firstConfig = true
        observeChanges { [weak self] in
            guard let self else { return }
            let config = settings.modelConfig
            let directory = settings.engineDirectory
            if firstConfig { firstConfig = false; return }
            // Debounce: steppers and text fields change several times in quick succession.
            configTask?.cancel()
            configTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(800))
                guard !Task.isCancelled, let self else { return }
                supervisor.setEngineDirectory(directory)
                supervisor.apply(config)
            }
        }
    }

    private func observeDictation() {
        observeChanges { [weak self] in
            guard let self else { return }
            let content: HUDModel.Content
            switch controller.state {
            case .recording: content = .recording
            case .transcribing, .inserting: content = .transcribing
            case .idle: content = controller.notice.map { .notice($0) } ?? .hidden
            }
            // Notices still show with the HUD off: they explain why nothing was typed.
            if settings.showHUD || content == .hidden || controller.notice != nil {
                hud.update(content)
            } else {
                hud.update(.hidden)
            }
        }
    }

    @discardableResult
    private func startHotkey() -> Bool {
        let ok = monitor.start()
        hotkeyTapFailed = !ok
        return ok
    }

    // MARK: - Windows

    private func showSettings() {
        if settingsWindow == nil {
            let recorder = HotkeyRecorderModel(
                onListeningChanged: { [weak self] listening in self?.monitor.setSuspended(listening) },
                onRecorded: { [weak self] hotkey in self?.settings.hotkey = hotkey }
            )
            let view = SettingsView(
                settings: settings,
                model: SettingsModel(hotkeyRecorder: recorder),
                microphones: microphones,
                supervisor: supervisor,
                downloader: downloader
            )
            settingsWindow = makeWindow(title: "Shout Settings", content: view)
        }
        present(settingsWindow)
    }

    private func showOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = makeWindow(title: "Shout", content: onboardingView())
        present(onboardingWindow)

        // macOS doesn't announce permission changes, so poll while the window is open.
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.permissionTick() }
        }
    }

    private func permissionTick() {
        permissions.refresh()
        if permissions.allGranted && !monitor.isRunning {
            startHotkey()
        }
        // Rebuild so the Input Monitoring hint reflects the latest tap attempt.
        if let window = onboardingWindow, window.isVisible {
            (window.contentViewController as? NSHostingController<OnboardingView>)?.rootView = onboardingView()
        } else {
            permissionTimer?.invalidate()
            permissionTimer = nil
        }
    }

    private func onboardingView() -> OnboardingView {
        OnboardingView(
            permissions: permissions,
            settings: settings,
            microphones: microphones,
            hotkeyName: settings.hotkey.displayName,
            hotkeyTapFailed: hotkeyTapFailed,
            onRelaunch: { [weak self] in self?.relaunch() },
            onDone: { [weak self] in
                self?.onboardingWindow?.close()
                self?.permissionTimer?.invalidate()
            }
        )
    }

    /// Quit and start again. A helper shell waits for this process to exit (after the engine
    /// has shut down) and then reopens the app bundle.
    private func relaunch() {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$2\"",
            "relaunch", String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath,
        ]
        do {
            try helper.run()
        } catch {
            Log.app.error("Couldn't start relaunch helper: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
    }

    private func makeWindow<Content: View>(title: String, content: Content) -> NSWindow {
        let window = NSWindow(contentViewController: NSHostingController(rootView: content))
        window.title = title
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }

    /// Shout has no Dock icon, so when its last window closes nothing hands focus back.
    /// Hiding the app returns it to whatever you were using before.
    public func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        let othersVisible = [settingsWindow, onboardingWindow].contains { $0 != nil && $0 !== closing && $0!.isVisible }
        if !othersVisible {
            DispatchQueue.main.async { NSApp.hide(nil) }
        }
    }

    private func present(_ window: NSWindow?) {
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}
