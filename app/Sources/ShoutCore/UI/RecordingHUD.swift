import AppKit
import Observation
import SwiftUI

/// What the floating indicator shows.
@MainActor
@Observable
final class HUDModel {
    enum Content: Equatable {
        case hidden
        case recording
        case transcribing
        case notice(DictationNotice)
    }

    var content: Content = .hidden
    var level: Float = 0
}

/// A small pill near the bottom of the screen. It's a non-activating panel that ignores
/// the mouse and can never become key, so it never steals focus from the text field.
@MainActor
final class RecordingHUD {
    let model = HUDModel()
    private let panel: HUDPanel

    init() {
        panel = HUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: HUDView(model: model))
    }

    func update(_ content: HUDModel.Content) {
        model.content = content
        if content == .hidden {
            panel.orderOut(nil)
            model.level = 0
        } else if !panel.isVisible {
            position()
            panel.orderFrontRegardless()
        }
    }

    private func position() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 40))
    }
}

private final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct HUDView: View {
    let model: HUDModel

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            pill
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var pill: some View {
        switch model.content {
        case .hidden:
            EmptyView()
        case .recording:
            HStack(spacing: 6) {
                Circle().fill(Color.red).frame(width: 6, height: 6)
                LevelSpike(level: model.level)
            }
            .modifier(PillStyle())
        case .transcribing:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Transcribing…")
            }
            .modifier(PillStyle())
        case let .notice(notice):
            HStack(spacing: 5) {
                Image(systemName: icon(for: notice.kind))
                    .foregroundStyle(notice.kind == .info ? Color.secondary : Color.orange)
                Text(notice.message).lineLimit(1)
            }
            .modifier(PillStyle())
        }
    }

    private func icon(for kind: DictationNotice.Kind) -> String {
        switch kind {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }
}

/// One waveform spike: five thin bars shaped low–high–low that grow with your voice.
private struct LevelSpike: View {
    let level: Float
    private let profile: [CGFloat] = [0.35, 0.7, 1, 0.7, 0.35]
    private let minHeight: CGFloat = 2
    private let maxHeight: CGFloat = 12

    var body: some View {
        // Keep a small visible shape during silence so it still reads as "listening".
        let loudness = CGFloat(max(level, 0.12))
        HStack(alignment: .center, spacing: 1.5) {
            ForEach(profile.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.primary)
                    .frame(width: 2, height: minHeight + (maxHeight - minHeight) * profile[index] * loudness)
            }
        }
        .frame(height: maxHeight)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}

private struct PillStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
    }
}
