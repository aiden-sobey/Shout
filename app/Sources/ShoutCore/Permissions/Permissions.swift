import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import Observation

/// The two permissions Shout needs, checked and requested in one place.
///
/// - Microphone: to record.
/// - Accessibility: for the keyboard event tap (it filters events, so it's not listen-only)
///   and for posting the ⌘V / typing events into other apps.
@MainActor
@Observable
public final class Permissions {
    public enum MicrophoneStatus: Sendable {
        case notDetermined, granted, denied
    }

    public private(set) var microphone: MicrophoneStatus = .notDetermined
    public private(set) var accessibility = false

    @ObservationIgnored private var accessibilityObserver: NSObjectProtocol?

    public init() {
        refresh()
        // macOS posts this whenever any app's Accessibility permission changes. The trusted
        // check can lag behind the switch in System Settings, so look again shortly after.
        accessibilityObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
    }

    public var allGranted: Bool {
        microphone == .granted && accessibility
    }

    public func refresh() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notDetermined
        default: microphone = .denied
        }
        accessibility = AXIsProcessTrusted()
    }

    public func requestMicrophone() async {
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            refresh()
        } else {
            open(.microphone)
        }
    }

    /// Shows the system "would like to control this computer" prompt (only the first time),
    /// which offers to open System Settings.
    public func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibility = AXIsProcessTrustedWithOptions(options)
        if !accessibility { open(.accessibility) }
    }

    public enum Pane: String {
        case microphone = "Privacy_Microphone"
        case accessibility = "Privacy_Accessibility"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    public func open(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
