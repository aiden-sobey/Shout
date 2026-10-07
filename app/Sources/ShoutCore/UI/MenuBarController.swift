import AppKit

/// The menu-bar icon and its menu. The icon reflects the dictation and engine state.
@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    struct Actions {
        var pasteLast: () -> Void
        var copyTranscript: (TranscriptRecord) -> Void
        var openSettings: () -> Void
        var openPermissions: () -> Void
        var quit: () -> Void
    }

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let actions: Actions
    private let controller: DictationController
    private let supervisor: EngineSupervisor
    private let permissions: Permissions
    private let settings: AppSettings
    private var hotkeyTapRunning: () -> Bool

    init(
        controller: DictationController,
        supervisor: EngineSupervisor,
        permissions: Permissions,
        settings: AppSettings,
        hotkeyTapRunning: @escaping () -> Bool,
        actions: Actions
    ) {
        self.controller = controller
        self.supervisor = supervisor
        self.permissions = permissions
        self.settings = settings
        self.hotkeyTapRunning = hotkeyTapRunning
        self.actions = actions
        super.init()
        menu.delegate = self
        item.menu = menu
        item.button?.toolTip = "Shout"
        observeChanges { [weak self] in self?.updateIcon() }
    }

    private func updateIcon() {
        // Touch every observed property so changes to any of them re-run this.
        let state = controller.state
        let engineReady = supervisor.isReady
        let engineFailed: Bool = {
            switch supervisor.state {
            case .failed, .modelMissing: true
            default: false
            }
        }()
        let permissionsOK = permissions.allGranted

        let symbol: String
        var tint: NSColor?
        switch state {
        case .recording:
            symbol = "mic.fill"
            tint = .systemRed
        case .transcribing, .inserting:
            symbol = "ellipsis.circle"
        case .idle:
            if !permissionsOK || engineFailed {
                symbol = "exclamationmark.triangle"
            } else if !engineReady {
                symbol = "mic.slash"
            } else {
                symbol = "mic"
            }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Shout")
        if let tint, let image {
            let config = NSImage.SymbolConfiguration(paletteColors: [tint])
            item.button?.image = image.withSymbolConfiguration(config)
            item.button?.image?.isTemplate = false
        } else {
            image?.isTemplate = true
            item.button?.image = image
        }
    }

    // Rebuilt every time the menu opens, so it's always current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(disabledItem(supervisor.state.label))
        menu.addItem(disabledItem("Hold \(settings.hotkey.displayName) to talk"))
        if !permissions.allGranted {
            menu.addItem(actionItem("Grant permissions…") { [actions] in actions.openPermissions() })
        } else if !hotkeyTapRunning() {
            menu.addItem(actionItem("Hotkey not active — check permissions…") { [actions] in actions.openPermissions() })
        }
        if SecureInput.isEnabled {
            menu.addItem(disabledItem("⚠︎ Secure input is on — hotkey paused"))
        }
        menu.addItem(.separator())

        let pasteLast = actionItem("Paste Last Transcript") { [actions] in actions.pasteLast() }
        pasteLast.isEnabled = !controller.recent.isEmpty
        menu.addItem(pasteLast)

        let recentItem = NSMenuItem(title: "Recent", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        if controller.recent.isEmpty {
            recentMenu.addItem(disabledItem("Nothing yet"))
        } else {
            for record in controller.recent {
                let flat = record.text.replacingOccurrences(of: "\n", with: " ")
                let title = flat.count > 60 ? String(flat.prefix(57)) + "…" : flat
                recentMenu.addItem(actionItem(title) { [actions] in actions.copyTranscript(record) })
            }
            recentMenu.addItem(.separator())
            recentMenu.addItem(disabledItem("Click one to copy it"))
        }
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        menu.addItem(.separator())
        let settingsItem = actionItem("Settings…") { [actions] in actions.openSettings() }
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        let quitItem = actionItem("Quit Shout") { [actions] in actions.quit() }
        quitItem.keyEquivalent = "q"
        menu.addItem(quitItem)
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func actionItem(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        return item
    }
}

private final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// Calls `apply` now and again whenever any observable property it read changes.
@MainActor
func observeChanges(_ apply: @escaping @MainActor () -> Void) {
    withObservationTracking {
        apply()
    } onChange: {
        Task { @MainActor in observeChanges(apply) }
    }
}
