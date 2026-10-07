import AppKit
import Carbon.HIToolbox

public enum InsertOutcome: Equatable, Sendable {
    case inserted
    /// A different app was in front by the time the text was ready, so it was only copied.
    case copiedBecauseFocusChanged
    /// Secure input was on (password field), so nothing was inserted or copied.
    case blockedBySecureInput
    case empty
}

public struct InsertionSettings: Equatable, Sendable {
    public var method: InsertionMethod
    public var restoreClipboard: Bool
    public var restoreDelay: Duration

    public init(method: InsertionMethod, restoreClipboard: Bool, restoreDelay: Duration) {
        self.method = method
        self.restoreClipboard = restoreClipboard
        self.restoreDelay = restoreDelay
    }
}

/// Puts text into whatever text field has focus in the frontmost app.
@MainActor
public final class TextInserter {
    // Clipboard managers that follow nspasteboard.org conventions skip items with these types.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private let pasteboard: NSPasteboard

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// - Parameter targetPID: the app that was in front when recording started, or nil for
    ///   "whatever is in front now" (used by the "Paste last transcript" menu item).
    public func insert(_ text: String, targetPID: pid_t?, settings: InsertionSettings) async -> InsertOutcome {
        guard !text.isEmpty else { return .empty }
        if SecureInput.isEnabled { return .blockedBySecureInput }
        if let targetPID, NSWorkspace.shared.frontmostApplication?.processIdentifier != targetPID {
            copyToClipboard(text)
            return .copiedBecauseFocusChanged
        }
        switch settings.method {
        case .paste:
            await paste(text, restore: settings.restoreClipboard, after: settings.restoreDelay)
        case .type:
            await type(text)
        }
        return .inserted
    }

    public func copyToClipboard(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Paste

    private func paste(_ text: String, restore: Bool, after delay: Duration) async {
        let saved = restore ? snapshot() : nil

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: Self.transientType)
        item.setData(Data(), forType: Self.concealedType)
        pasteboard.writeObjects([item])
        let ourChangeCount = pasteboard.changeCount

        postKeystroke(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand)

        guard let saved else { return }
        try? await Task.sleep(for: delay)
        // Only restore if nobody else has put something on the clipboard since.
        guard pasteboard.changeCount == ourChangeCount else {
            Log.insert.notice("Clipboard changed during paste; not restoring")
            return
        }
        restoreSnapshot(saved)
    }

    private typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    private func snapshot() -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    private func restoreSnapshot(_ saved: Snapshot) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entries { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: - Type

    /// Types the text as keyboard events, one character at a time. Slower than pasting,
    /// but doesn't touch the clipboard and works in apps that block paste.
    ///
    /// Line breaks are sent as Shift+Return: a plain Return would send the message in Slack
    /// and most chat apps, while Shift+Return starts a new line there and in text editors.
    private func type(_ text: String) async {
        let source = CGEventSource(stateID: .hidSystemState)
        for character in text {
            if character.isNewline {
                postKeystroke(virtualKey: CGKeyCode(kVK_Return), flags: .maskShift)
                try? await Task.sleep(for: .milliseconds(2))
                continue
            }
            let units = Array(String(character).utf16)
            for keyDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: keyDown) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticEventMarker)
                event.post(tap: .cghidEventTap)
            }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    private func postKeystroke(virtualKey: CGKeyCode, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: virtualKey, keyDown: keyDown) else {
                Log.insert.error("Couldn't create keyboard event")
                return
            }
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: HotkeyMonitor.syntheticEventMarker)
            event.post(tap: .cghidEventTap)
        }
    }
}

public enum SecureInput {
    /// True while any app has Secure Event Input on (password fields, Terminal's Secure
    /// Keyboard Entry, some password managers). Event taps can't see keys in that state.
    public static var isEnabled: Bool {
        IsSecureEventInputEnabled()
    }
}
