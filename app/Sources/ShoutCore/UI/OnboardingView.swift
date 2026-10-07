import SwiftUI

/// First-run window: one row per permission, closes itself once everything is granted.
struct OnboardingView: View {
    let permissions: Permissions
    let hotkeyName: String
    /// True if the event tap couldn't start even though Accessibility looks granted.
    let hotkeyTapFailed: Bool
    let onRelaunch: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Set up Shout").font(.title2.bold())
                Text("Shout needs two permissions. Everything stays on this Mac: audio is transcribed locally and never saved.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PermissionRow(
                title: "Microphone",
                detail: "To hear you while you hold the hotkey.",
                granted: permissions.microphone == .granted,
                actionTitle: permissions.microphone == .notDetermined ? "Allow" : "Open Settings"
            ) {
                Task { await permissions.requestMicrophone() }
            }

            PermissionRow(
                title: "Accessibility",
                detail: "To notice the hotkey in any app and paste text where your cursor is. "
                    + "After turning it on in System Settings, come back here.",
                granted: permissions.accessibility,
                actionTitle: "Open Settings"
            ) {
                permissions.requestAccessibility()
            }

            if hotkeyTapFailed && permissions.accessibility {
                Text("The hotkey still can't be watched. Also turn Shout on under Privacy & Security → Input Monitoring, then relaunch Shout.")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Open Input Monitoring") { permissions.open(.inputMonitoring) }
                    Button("Relaunch Shout", action: onRelaunch)
                }
            }

            Divider()

            HStack {
                Text("Then hold **\(hotkeyName)**, speak, and let go.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissions.allGranted)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(granted ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted {
                Button(actionTitle, action: action)
            }
        }
    }
}
