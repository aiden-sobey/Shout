import CoreGraphics
import Foundation
import os

/// Watches the keyboard (and the middle/side mouse buttons) system-wide with a CGEventTap
/// and reports hotkey actions.
///
/// The tap is an active filter (not listen-only) so combo hotkeys can be swallowed.
/// That needs the Accessibility permission. The tap runs on its own thread; actions
/// are delivered on the main queue.
public final class HotkeyMonitor: @unchecked Sendable {
    /// Marks events Shout posts itself (the ⌘V paste) so the tap ignores them.
    public static let syntheticEventMarker: Int64 = 0x5348_4F55  // "SHOU"

    private let lock = NSLock()
    private var matcher: HotkeyMatcher
    private var suspended = false
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?
    private let onAction: @Sendable (HotkeyAction) -> Void
    private let log = Logger(subsystem: Log.subsystem, category: "hotkey")

    public init(hotkey: Hotkey, onAction: @escaping @Sendable (HotkeyAction) -> Void) {
        self.matcher = HotkeyMatcher(hotkey: hotkey)
        self.onAction = onAction
    }

    deinit { stop() }

    public var isRunning: Bool {
        lock.withLock { tap != nil }
    }

    /// Starts the tap. Returns false if macOS refused it, which means a missing permission.
    @discardableResult
    public func start() -> Bool {
        if isRunning { return true }
        let ready = DispatchSemaphore(value: 0)
        let started = OSAllocatedUnfairLock(initialState: false)
        let thread = Thread { [weak self] in
            guard let self else { ready.signal(); return }
            let ok = self.installTapOnCurrentRunLoop()
            started.withLock { $0 = ok }
            ready.signal()
            if ok { CFRunLoopRun() }
        }
        thread.name = "Shout.HotkeyMonitor"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        let ok = started.withLock { $0 }
        if ok {
            lock.withLock { self.thread = thread }
            log.info("Event tap started")
        } else {
            log.error("Event tap could not be created (Accessibility permission missing?)")
        }
        return ok
    }

    public func stop() {
        let (tap, runLoop) = lock.withLock { () -> (CFMachPort?, CFRunLoop?) in
            defer { self.tap = nil; self.runLoop = nil; self.thread = nil; matcher.reset() }
            return (self.tap, self.runLoop)
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    public func update(hotkey: Hotkey) {
        lock.withLock { matcher.hotkey = hotkey }
    }

    /// Ignore the keyboard, e.g. while the Settings recorder is choosing a new hotkey.
    public func setSuspended(_ value: Bool) {
        lock.withLock {
            suspended = value
            matcher.reset()
        }
    }

    private func installTapOnCurrentRunLoop() -> Bool {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.otherMouseUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        let runLoop = CFRunLoopGetCurrent()
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        lock.withLock {
            self.tap = tap
            self.runLoop = runLoop
        }
        return true
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS turns slow or interrupted taps off. Turn it straight back on.
            if let tap = lock.withLock({ self.tap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            log.notice("Event tap was disabled by the system; re-enabled")
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == Self.syntheticEventMarker {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags.rawValue
        let input: KeyInput
        switch type {
        case .flagsChanged: input = .flagsChanged(keyCode: keyCode, flags: flags)
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            input = .keyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        case .keyUp: input = .keyUp(keyCode: keyCode, flags: flags)
        case .otherMouseDown, .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            input = type == .otherMouseDown ? .mouseDown(button: button, flags: flags) : .mouseUp(button: button, flags: flags)
        default: return Unmanaged.passUnretained(event)
        }

        let decision = lock.withLock { () -> HotkeyDecision in
            if suspended { return .passThrough }
            return matcher.handle(input)
        }
        if let action = decision.action {
            let onAction = self.onAction
            DispatchQueue.main.async { onAction(action) }
        }
        return decision.swallow ? nil : Unmanaged.passUnretained(event)
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handle(type: type, event: event)
}
